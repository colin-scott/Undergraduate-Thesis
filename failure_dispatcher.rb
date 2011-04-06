# just in charge of issuing measurements and logging/emailing results
class FailureDispatcher
    def initialize
        @controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
        @registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)

        acl=ACL.new(%w[deny all
					allow *.cs.washington.edu
					allow localhost
					allow 127.0.0.1
					])

        @mutex = Mutex.new
        connect_to_drb # sets @rtrSvc
        @have_retried_connection = false # so that multiple threads don't try to reconnect to DRb

        @ipInfo = IpInfo.new

        @failure_analyzer = FailureAnalyzer.new(@ipInfo)
        
        @db = DatabaseInterface.new

        @historical_trace_timestamp, @node2target2trace = YAML.load_file FailureIsolation::HistoricalTraces

        @revtr_cache = RevtrCache.new(@db, @ipInfo)

        Thread.new do
            loop do
                sleep 60 * 60 * 24
                @historical_trace_timestamp, @node2target2trace = YAML.load_file FailureIsolation::HistoricalTraces
            end
        end
    end

    def connect_to_drb()
        @mutex.synchronize do
            if !@have_retried_connection
                @have_retried_connection = true
                uri_location = "http://revtr.cs.washington.edu/vps/failure_isolation/spoof_only_rtr_module.txt"
                uri = Net::HTTP.get_response(URI.parse(uri_location)).body
                @rtrSvc = DRbObject.new nil, uri
            end
        end
    end

    # precondition: stillconnected are able to reach dst
    def isolate_outages(srcdst2stillconnected, srcdst2formatted_connected, srcdst2formatted_unconnected, testing=false) # this testing flag is terrrrible
        @registrar.garbage_collect # XXX HACK. andddd, we still have a memory leak...
        @have_retried_connection = false

        # first filter out any outages where no nodes are actually registered
        # with the controller
        $stderr.puts "before filtering, srcdst2stillconnected: #{srcdst2stillconnected.inspect}"
        registered_vps = @controller.hosts.clone
        srcdst2stillconnected.delete_if do |srcdst, still_connected|
            !registered_vps.include?(srcdst[0]) || (registered_vps & still_connected).empty?
        end
        $stderr.puts "after filtering, srcdst2stillconnected: #{srcdst2stillconnected.inspect}"

        return if srcdst2stillconnected.empty? # optimization

        # will become:
        #   [spoof_ping_time, spooftr_time, revtr_time, ping_time, tr_time]
        measurement_times = []
        # quickly isolate the directions of the failures
        measurement_times << ["spoof_ping", Time.new]
        srcdst2pings_towards_src = issue_pings_towards_srcs(srcdst2stillconnected)
        $stderr.puts "srcdst2pings_towards_src: #{srcdst2pings_towards_src.inspect}"

        # if we control one of the targets, send out spoofed traceroutes in
        # the opposite direction for ground truth information
        symmetric_srcdst2stillconnected, srcdst2dstsrc = check4targetswecontrol(srcdst2stillconnected, registered_vps)
        
        # we check the forward direction by issuing spoofed traceroutes (rather than pings)
        measurement_times << ["spoof_tr", Time.new]
        srcdst2spoofed_tr = issue_spoofed_traceroutes(symmetric_srcdst2stillconnected)
        $stderr.puts "srcdst2spoofed_tr: #{srcdst2spoofed_tr.inspect}"

        # thread out on each src, dst
        srcdst2stillconnected.keys.each do |srcdst|
            src, dst = srcdst
            Thread.new do
                if srcdst2dstsrc.include? srcdst
                    dsthostname, srcip = srcdst2dstsrc[srcdst]
                    analyze_results_with_symmetry(src, dst, dsthostname, srcip, srcdst2stillconnected[srcdst],
                                    srcdst2formatted_connected[srcdst], srcdst2formatted_unconnected[srcdst],
                                    srcdst2pings_towards_src[srcdst], srcdst2spoofed_tr[srcdst],
                                    srcdst2spoofed_tr[srcdst2dstsrc[srcdst]], deep_copy(measurement_times), testing)
                else
                    analyze_results(src, dst, srcdst2stillconnected[srcdst],
                                    srcdst2formatted_connected[srcdst], srcdst2formatted_unconnected[srcdst],
                                    srcdst2pings_towards_src[srcdst], srcdst2spoofed_tr[srcdst],
                                    deep_copy(measurement_times), testing)
                end
            end
        end
    end

   # private

    def check4targetswecontrol(srcdst2stillconnected, registered_hosts)
       srcdst2dstsrc = {}
       symmetric_srcdst2stillconnected = srcdst2stillconnected.clone
       srcdst2stillconnected.each do |srcdst, stillconnected|
            src, dst = srcdst
            if FailureIsolation::SpooferTargets.include? dst
                hostname = FailureIsolation::SpooferIP2Hostname[dst]
                if registered_hosts.include? hostname
                    swapped = [hostname, $pl_host2ip[src]]
                    $stderr.puts "check4targetswecontrol(), swapped #{swapped.inspect} srcdst #{srcdst.inspect}"
                    srcdst2dstsrc[srcdst] = swapped
                    symmetric_srcdst2stillconnected[swapped] = stillconnected
                end
            end
       end

       [symmetric_srcdst2stillconnected, srcdst2dstsrc]
    end

    def analyze_results(src, dst, spoofers_w_connectivity, formatted_connected, formatted_unconnected,
                        pings_towards_src, spoofed_tr, measurement_times, testing=false)
        $stderr.puts "analyze_results: #{src}, #{dst}"

        direction, historical_tr_hops, historical_trace_timestamp, spoofed_revtr_hops, cached_revtr_hops,
            ping_responsive, tr, dataset = gather_additional_data(src, dst, pings_towards_src, spoofed_tr, measurement_times)

        insert_measurement_durations(measurement_times)

        log_name = get_uniq_filename(src, dst)

        if(@failure_analyzer.passes_filtering_heuristics(src, dst, tr, spoofed_tr, ping_responsive, historical_tr_hops, direction, testing))

            jpg_output = generate_jpg(log_name, src, dst, direction, dataset, tr, spoofed_tr, historical_tr_hops, spoofed_revtr_hops,
                             cached_revtr_hops)

            graph_url = generate_web_symlink(jpg_output)

            Emailer.deliver_isolation_results(src, @ipInfo.format(dst), dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr_hops, historical_trace_timestamp,
                                          spoofed_revtr_hops, cached_revtr_hops, graph_url, measurement_times, testing)

            $stderr.puts "Attempted to send isolation_results email for #{src} #{dst} testing #{testing}..."
        end

        if(!testing)
            log_isolation_results(log_name, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr_hops, historical_trace_timestamp,
                                          spoofed_revtr_hops, cached_revtr_hops)
        end
    end

    def analyze_results_with_symmetry(src, dst, dsthostname, srcip, spoofers_w_connectivity,
                                      formatted_connected, formatted_unconnected, pings_towards_src,
                                      spoofed_tr, dst_spoofed_tr, measurement_times, testing=false)
        $stderr.puts "analyze_results_with_symmetry: #{src}, #{dst}"

        direction, historical_tr_hops, historical_trace_timestamp, spoofed_revtr_hops, cached_revtr_hops,
            ping_responsive, tr, dataset, times = gather_additional_data(src, dst, pings_towards_src, spoofed_tr, measurement_times)

        dst_tr = issue_normal_traceroute(dsthostname, [srcip]) 

        insert_measurement_durations(measurement_times)

        log_name = get_uniq_filename(src, dst)
        
        if(@failure_analyzer.passes_filtering_heuristics(src, dst, tr, spoofed_tr, ping_responsive, historical_tr_hops, direction, testing))

            jpg_output = generate_jpg(log_name, src, dst, direction, dataset, tr, spoofed_tr, historical_tr_hops, spoofed_revtr_hops,
                             cached_revtr_hops)
 
            graph_url = generate_web_symlink(jpg_output)

            Emailer.deliver_symmetric_isolation_results(src, @ipInfo.format(dst), dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          dst_tr, dst_spoofed_tr,
                                          historical_tr_hops, historical_trace_timestamp,
                                          spoofed_revtr_hops, cached_revtr_hops, graph_url, measurement_times, testing)

            $stderr.puts "Attempted to send symmetric isolation_results email for #{src} #{dst} testing #{testing}..."
        end

        if(!testing)
            log_symmetric_isolation_results(log_name, src, @ipInfo.format(dst), dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          dst_tr, dst_spoofed_tr,
                                          historical_tr_hops, historical_trace_timestamp,
                                          spoofed_revtr_hops, cached_revtr_hops, testing)
        end
    end

    # this is really ugly -- but it elimanates redundancy between
    # analyze_results() and analyze_results_with_symmetry()
    def gather_additional_data(src, dst, pings_towards_src, spoofed_tr, measurement_times)
        reverse_problem = pings_towards_src.empty?
        forward_problem = !forward_path_reached?(spoofed_tr, dst)

        direction = @failure_analyzer.infer_direction(reverse_problem, forward_problem)

        # HistoricalForwardHop objects
        historical_tr_hops, historical_trace_timestamp = retrieve_historical_tr(src, dst)

        historical_tr_hops.each do |hop|
            # XXX thread out on this to make it faster? Ask Dave for a faster
            # way?
            hop.reverse_path = fetch_cached_revtr(src, hop.ip)
        end

        measurement_times << ["revtr", Time.new]
        spoofed_revtr_hops = issue_spoofed_revtr(src, dst, historical_tr_hops.map { |hop| hop.ip })

        cached_revtr_hops = fetch_cached_revtr(src, dst)

        # We would like to know whether the hops on the historicalfoward/reverse/historicalreverse paths
        # are pingeable from the source. Send pings, and append the results to
        # the strings in the arrays (terrible, terrible, terrible)
        measurement_times << ["ping", Time.new]

        ping_responsive = issue_pings(src, dst, historical_tr_hops,  spoofed_tr,
                                      spoofed_revtr_hops[0].is_a?(Symbol) ? [] : spoofed_revtr_hops,
                                      cached_revtr_hops)

        fetch_historical_pingability!(historical_tr_hops, spoofed_tr,
                                      spoofed_revtr_hops[0].is_a?(Symbol) ? [] : spoofed_revtr_hops,
                                      cached_revtr_hops)

        # maybe not threadsafe, but fuckit
        measurement_times << ["tr_time", Time.new]
        tr = issue_normal_traceroute(src, [dst])

        dataset = FailureIsolation::get_dataset(dst)
        
        [direction, historical_tr_hops, historical_trace_timestamp, spoofed_revtr_hops, cached_revtr_hops,
            ping_responsive, tr, dataset]
    end

    def generate_jpg(log_name, src, dst, direction, dataset, tr, spoofed_tr, historical_tr_hops, spoofed_revtr_hops,
                             cached_revtr_hops)
        jpg_output = "#{FailureIsolation::DotFiles}/#{log_name}.jpg"

        Dot::generate_jpg(src, dst, direction, dataset, tr, spoofed_tr, historical_tr_hops, spoofed_revtr_hops,
                             cached_revtr_hops, jpg_output)

        jpg_output
    end

    # given an array of the form:
    #   [[measurement_type, time], ...]
    # Transform it into:
    #   [[measurement_type, time, duration], ... ]
    def insert_measurement_durations(measurement_times)
        0.upto(measurement_times.size - 2) do |i|
            duration = measurement_times[i+1][1] - measurement_times[i][1] 
            measurement_times[i] << "(#{duration} seconds)"
        end
    end

    def generate_web_symlink(jpg_output)
        t = Time.new
        subdir = "#{t.year}.#{t.month}.#{t.day}"
        abs_path = FailureIsolation::WebDirectory+"/"+subdir
        FileUtils.mkdir_p(abs_path)
        basename = File.basename(jpg_output)
        File.symlink(jpg_output, abs_path+"/#{basename}")
        "http://revtr.cs.washington.edu/isolation_graphs/#{subdir}/#{basename}"
    end

    def fetch_cached_revtr(src,dst)
        $stderr.puts "fetch_cached_revtr(#{src}, #{dst})"

        dst = dst.ip if dst.is_a?(Hop)

        path = @revtr_cache.get_cached_reverse_path(src, dst)
        
        # XXX HACKKK. we want to print bad cache results in our email, which takes
        # on an array of hacky non-valid ReverseHop objects...
        path = path.to_s.split("\n").map { |x| ReverseHop.new(x, @ipInfo) } unless path.valid

        path
    end

    def retrieve_historical_tr(src, dst)
        if @node2target2trace.include? src and @node2target2trace[src].include? dst
            historical_tr_ttlhoptuples = @node2target2trace[src][dst]
            historical_trace_timestamp = @historical_trace_timestamp
        else
            historical_tr_ttlhoptuples = []
            historical_trace_timestamp = nil
        end

        $LOG.puts "isolate_outage(#{src}, #{dst}), historical_traceroute_results: #{historical_tr_ttlhoptuples.inspect}"

        # XXX why is this a nested array?
        [historical_tr_ttlhoptuples.map { |ttlhop| HistoricalForwardHop.new(ttlhop[0], ttlhop[1], @ipInfo) }, historical_trace_timestamp]
    end

    def issue_pings_towards_srcs(srcdst2stillconnected)
        # hash is target2receiver2succesfulvps
        spoofed_ping_results = @registrar.receive_batched_spoofed_pings(srcdst2stillconnected)

        $LOG.puts "issue_pings_towards_srcs, spoofed_ping_results: #{spoofed_ping_results.inspect}"

        srcdst2pings_towards_src = {}

        srcdst2stillconnected.keys.each do |srcdst|
            src, dst = srcdst
            if spoofed_ping_results.nil? || spoofed_ping_results[dst].nil? || spoofed_ping_results[dst][src].nil?
                srcdst2pings_towards_src[srcdst] = []
            else
                srcdst2pings_towards_src[srcdst] = spoofed_ping_results[dst][src]
            end
        end

        srcdst2pings_towards_src
    end

    def issue_spoofed_traceroutes(srcdst2stillconnected)
        #$LOG.puts "isolate_spoofed_traceroutes, srcdst2stillconnected: #{srcdst2stillconnected.inspect}"
        srcdst2sortedttlrtrs = @registrar.batch_spoofed_traceroute(srcdst2stillconnected)

        srcdst2spoofed_tr = {}

        #$LOG.puts "isolate_spoofed_traceroutes, srcdst2ttl2rtrs: #{srcdst2sortedttlrtrs.inspect}"

        srcdst2stillconnected.keys.each do |srcdst|
            src, dst = srcdst
            if srcdst2sortedttlrtrs.nil? || srcdst2sortedttlrtrs[srcdst].nil?
                srcdst2spoofed_tr[srcdst] = []
            else
                srcdst2spoofed_tr[srcdst] = srcdst2sortedttlrtrs[srcdst].map do |ttlrtrs|
                    SpoofedForwardHop.new(ttlrtrs, @ipInfo) 
                end
            end
        end

        srcdst2spoofed_tr
    end

    # precondition: targets is a single element array
    def issue_normal_traceroute(src, targets)
        dest2ttlhoptuples = @registrar.traceroute(src, targets, true)
        dst = targets[0] # ugghh...

        $LOG.puts "isolate_outage(#{src}, #{dst}), normal_traceroute_results: #{dest2ttlhoptuples.inspect}"

        if dest2ttlhoptuples.nil? || dest2ttlhoptuples[dst].nil?
            tr_ttlhoptuples = []
        else
            tr_ttlhoptuples = dest2ttlhoptuples[dst]
        end

        tr_ttlhoptuples.map { |ttlhop| ForwardHop.new(ttlhop, @ipInfo) }
    end

    # XXX change me later to deal with revtrs from forward hops
    def issue_spoofed_revtr(src, dst, historical_hops)
        begin
            srcdst2revtr = (historical_hops.empty?) ? @rtrSvc.get_reverse_paths([[src, dst]]) :
                                                      @rtrSvc.get_reverse_paths([[src, dst]], [historical_hops])
        rescue DRb::DRbConnError => e
            connect_to_drb()
            return [:drb_connection_refused]
        rescue Exception => e
            Emailer.deliver_isolation_exception("#{e} \n#{e.backtrace.join("<br />")}") 
            connect_to_drb()
            return [:drb_exception]
        end

        $LOG.puts "isolate_outage(#{src}, #{dst}), srcdst2revtr: #{srcdst2revtr.inspect}"

        if srcdst2revtr.nil? || srcdst2revtr[[src,dst]].nil?
            return [:nil_return_value]
        end
                
        revtr = srcdst2revtr[[src,dst]]
        revtr = revtr.to_sym if revtr.is_a?(String) # dave switched on me...
        
        if revtr.is_a?(Symbol)
            # The request failed -- the symbol tells us the cause of the failure
            spoofed_revtr = [revtr]
        else
            # XXX string -> array -> string. meh.
            spoofed_revtr = revtr.get_revtr_string.split("\n").map { |formatted| ReverseHop.new(formatted, @ipInfo) }
        end

        #$LOG.puts "isolate_outage(#{src}, #{dst}), spoofed_revtr: #{spoofed_revtr.inspect}"
        
        spoofed_revtr
    end

    # We would like to know whether the hops on the historicalfoward/reverse/historicalreverse paths
    # are pingeable from the source. Send pings, update
    # hop.ping_responsive, and return the responsive pings
    def issue_pings(source, dest, historical_tr_hops, spoofed_tr, spoofed_revtr_hops, cached_revtr_hops)
        all_hop_sets = [historical_tr_hops, spoofed_tr, spoofed_revtr_hops, cached_revtr_hops]
        all_targets = Set.new
        all_hop_sets.each { |hops| all_targets |= (hops.map { |hop| hop.ip }) }
        all_targets.add dest

        responsive = @registrar.ping(source, all_targets.to_a, true)
        $stderr.puts "Responsive to ping: #{responsive.inspect}"

        # update reachability
        all_hop_sets.each do |hop_set|
            hop_set.each { |hop| hop.ping_responsive = responsive.include? hop.ip }
        end

        responsive
    end

    # XXX Am I giving Ethan all of these hops properly?
    def fetch_historical_pingability!(historical_tr_hops, spoofed_tr_hops, spoofed_revtr_hops, cached_revtr_hops)
        # TODO: redundannnnttt
        all_hop_sets = [historical_tr_hops, spoofed_revtr_hops, spoofed_tr_hops, cached_revtr_hops]
        all_targets = Set.new
        all_hop_sets.each { |hops| all_targets |= (hops.map { |hop| hop.ip }) }

        ip2lastresponsive = @db.fetch_pingability(all_targets.to_a)

        $stderr.puts "fetch_historical_pingability(), ip2lastresponsive #{ip2lastresponsive.inspect}"

        # update historical reachability
        all_hop_sets.each do |hop_set|
            hop_set.each { |hop| hop.last_responsive = ip2lastresponsive[hop.ip] }
        end
    end

    def get_uniq_filename(src, dst)
        t = Time.new
        "#{src}_#{dst}_#{t.year}#{t.month}#{t.day}#{t.hour}#{t.min}#{t.sec}"
    end

    # first arg must be the filename
    def log_isolation_results(*args)
        filename = args.shift
        File.open(FailureIsolation::IsolationResults+"/"+filename+".yml", "w") { |f| YAML.dump(args, f) }
    end

    # first arg must be the filename
    def log_symmetric_isolation_results(*args)
        filename = args.shift
        File.open(FailureIsolation::SymmetricIsolationResults+"/"+filename+".yml", "w") { |f| YAML.dump(args, f) }
    end
end

