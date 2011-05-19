require 'isolation_module'
require 'drb'
require 'drb/acl'
require 'thread'
require 'ip_info'
require 'db_interface'
require 'yaml'
require 'revtr_cache_interface'
require 'net/http'
require 'hops'
require 'mkdot'
require 'reverse_traceroute_cache'
require 'timeout'
require 'failure_analyzer'
require 'mail'

# TODO: log additional traceroutes
#       convert logs to OBJECT dumps to allow for forward /and/ backward
#       compatiability muthafucka

# just in charge of issuing measurements and logging/emailing results
class FailureDispatcher
    def initialize
        @@revtr_timeout = 200
        
        @controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
        @registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)

        acl=ACL.new(%w[deny all
					allow *.cs.washington.edu
					allow localhost
					allow 127.0.0.1
					])

        @mutex = Mutex.new
        @spoof_tr_mutex = Mutex.new

        connect_to_drb() # sets @rtrSvc
        @have_retried_connection = false # so that multiple threads don't try to reconnect to DRb

        @ipInfo = IpInfo.new

        @failure_analyzer = FailureAnalyzer.new(@ipInfo, self)
        
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
                begin
                    @have_retried_connection = true
                    uri_location = "http://revtr.cs.washington.edu/vps/failure_isolation/spoof_only_rtr_module.txt"
                    uri = Net::HTTP.get_response(URI.parse(uri_location)).body
                    @rtrSvc = DRbObject.new nil, uri
                    @rtrSvc.respond_to?(:anything?)
                rescue DRb::DRbConnError
                    Emailer.deliver_isolation_exception("Revtr Service is down!", "choffnes@cs.washington.edu")
                end 
            end
        end
    end

    # precondition: stillconnected are able to reach dst
    def isolate_outages(srcdst2stillconnected, srcdst2formatted_connected, srcdst2formatted_unconnected, testing=false) # this testing flag is terrrrible
        @registrar.garbage_collect # XXX HACK. andddd, we still have a memory leak...
        @have_retried_connection = false

        # first filter out any outages where no nodes are actually registered
        # with the controller
        $LOG.puts "before filtering, srcdst2stillconnected: #{srcdst2stillconnected.inspect}"
        registered_vps = @controller.hosts.clone
        srcdst2stillconnected.delete_if do |srcdst, still_connected|
            !registered_vps.include?(srcdst[0]) || (registered_vps & still_connected).empty?
        end
        $LOG.puts "after filtering, srcdst2stillconnected: #{srcdst2stillconnected.inspect}"

        return if srcdst2stillconnected.empty? # optimization

        measurement_times = []

        # quickly isolate the directions of the failures
        measurement_times << ["spoof_ping", Time.new]
        srcdst2pings_towards_src = issue_pings_towards_srcs(srcdst2stillconnected)
        #$LOG.puts "srcdst2pings_towards_src: #{srcdst2pings_towards_src.inspect}"

        # if we control one of the targets, send out spoofed traceroutes in
        # the opposite direction for ground truth information
        symmetric_srcdst2stillconnected, srcdst2dstsrc = check4targetswecontrol(srcdst2stillconnected, registered_vps)
        
        # we check the forward direction by issuing spoofed traceroutes (rather than pings)
        measurement_times << ["spoof_tr", Time.new]
        srcdst2spoofed_tr = {}
        @spoof_tr_mutex.synchronize do
          srcdst2spoofed_tr = issue_spoofed_traceroutes(symmetric_srcdst2stillconnected)
        end
        #$LOG.puts "srcdst2spoofed_tr: #{srcdst2spoofed_tr.inspect}"

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
                    #$LOG.puts "check4targetswecontrol(), swapped #{swapped.inspect} srcdst #{srcdst.inspect}"
                    srcdst2dstsrc[srcdst] = swapped
                    symmetric_srcdst2stillconnected[swapped] = stillconnected
                end
            end
       end

       [symmetric_srcdst2stillconnected, srcdst2dstsrc]
    end


    # I should /not/ have made a damn distinction between analyze and analyze_symmetric 
    def analyze_results(src, dst, spoofers_w_connectivity, formatted_connected, formatted_unconnected,
                        pings_towards_src, spoofed_tr, measurement_times, testing=false)
        $LOG.puts "analyze_results: #{src}, #{dst}"

        # wow, this is a mouthful
        direction, historical_tr, historical_trace_timestamp, spoofed_revtr, historical_revtr,
            ping_responsive, tr, dataset, suspected_failure, as_hops_from_dst, as_hops_from_src, 
            alternate_paths, measured_working_direction, path_changed, additional_traceroutes, measurements_reissued = gather_additional_data(
                                                       src, dst, pings_towards_src, spoofed_tr, measurement_times, spoofers_w_connectivity,testing)

        insert_measurement_durations(measurement_times)

        log_name = get_uniq_filename(src, dst)

        passed_filters = @failure_analyzer.passes_filtering_heuristics?(src, dst, tr, spoofed_tr,
                                                             ping_responsive, historical_tr, historical_revtr, direction, testing)

        $LOG.puts "analyze_results: #{src}, #{dst}, passed_filters: #{passed_filters}"

        if(passed_filters)
            jpg_output = generate_jpg(log_name, src, dst, direction, dataset, tr, spoofed_tr, historical_tr, spoofed_revtr,
                             historical_revtr, additional_traceroutes)

            graph_url = generate_web_symlink(jpg_output)

            Emailer.deliver_isolation_results(src, @ipInfo.format(dst), dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr, graph_url, measurement_times,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurements_reissued, additional_traceroutes, testing)

            $LOG.puts "Attempted to send isolation_results email for #{src} #{dst} testing #{testing}..."
        else
            $LOG.puts "Heuristic failure! measurement times: #{measurement_times.inspect}"
        end

        if(!testing)
            log_isolation_results(Outage.new(log_name, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters, additional_traceroutes))
        end

        return passed_filters
    end

    # HMMMM, terribly redundant
    def analyze_results_with_symmetry(src, dst, dsthostname, srcip, spoofers_w_connectivity,
                                      formatted_connected, formatted_unconnected, pings_towards_src,
                                      spoofed_tr, dst_spoofed_tr, measurement_times, testing=false)
        $LOG.puts "analyze_results_with_symmetry: #{src}, #{dst}"

        # wow, this is a mouthful
        direction, historical_tr, historical_trace_timestamp, spoofed_revtr, historical_revtr,
            ping_responsive, tr, dataset, suspected_failure, as_hops_from_dst, as_hops_from_src, 
            alternate_paths, measured_working_direction, path_changed, additional_traceroutes,
            measurements_reissued = gather_additional_data(
                                                       src, dst, pings_towards_src, spoofed_tr, measurement_times, spoofers_w_connectivity,testing)

        dst_tr = issue_normal_traceroutes(dsthostname, [srcip])[srcip]

        insert_measurement_durations(measurement_times)

        log_name = get_uniq_filename(src, dst)

        passed_filters = @failure_analyzer.passes_filtering_heuristics?(src, dst, tr, spoofed_tr, ping_responsive,
                                                                        historical_tr, historical_revtr, direction, testing)
        
        if(passed_filters)
            jpg_output = generate_jpg(log_name, src, dst, direction, dataset, tr, spoofed_tr, historical_tr, spoofed_revtr,
                             historical_revtr, additional_traceroutes)
 
            graph_url = generate_web_symlink(jpg_output)

            Emailer.deliver_symmetric_isolation_results(src, @ipInfo.format(dst), dataset,
                                          direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          dst_tr, dst_spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr, graph_url, measurement_times,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          additional_traceroutes,
                                          measurements_reissued, testing)

            $LOG.puts "Attempted to send symmetric isolation_results email for #{src} #{dst} testing #{testing}..."
        else
            $LOG.puts "Heuristic failure! measurement times: #{measurement_times.inspect}"
        end

        if(!testing)
            log_isolation_results(SymmetricOutage.new(log_name, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          dst_tr, dst_spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters, additional_traceroutes))
        end
    end

    def paths_diverge?(src, dst, spoofed_tr, tr)
        spoofed_tr_loop = spoofed_tr.contains_loop?()
        tr_loop = tr.contains_loop?()
        divergence = false
        compressed_spooftr = spoofed_tr.compressed_as_path
        compressed_tr = tr.compressed_as_path

        # trs and spooftrs sometimes differ in length. We look at the common
        # prefix
        [compressed_tr.size, compressed_spooftr.size].min.times do |i|
           # occasionally spooftr will get *'s where tr doesn't, or vice
           # versa. Look to make sure the next hop isn't the same
           if compressed_tr[i] != compressed_spooftr[i] and 
               compressed_tr[i] != compressed_spooftr[i+1] and compressed_tr[i+1] != compressed_spooftr[i]
             divergence = true
             break
           end
        end

        $LOG.puts "spooftr_loop!(#{src}, #{dst}) #{spoofed_tr.map { |h| h.ip }}" if spoofed_tr_loop
        $LOG.puts "tr_loop!(#{src}, #{dst}) #{tr.map { |h| h.ip}}" if tr_loop
        $LOG.puts "divergence!(#{src}, #{dst}) #{compressed_spooftr} --tr-- #{compressed_tr}" if divergence

        return spoofed_tr_loop || tr_loop || divergence
    end

    # this is really ugly -- but it elimanates redundancy between
    # analyze_results() and analyze_results_with_symmetry()
    def gather_additional_data(src, dst, pings_towards_src, spoofed_tr, measurement_times, spoofers_w_connectivity, testing)
        reverse_problem = pings_towards_src.empty?
        forward_problem = !spoofed_tr.reached?(dst)

        direction = @failure_analyzer.infer_direction(reverse_problem, forward_problem)

        # HistoricalForwardHop objects
        historical_tr, historical_trace_timestamp = retrieve_historical_tr(src, dst)

        historical_tr.each do |hop|
            # XXX thread out on this to make it faster? Ask Dave for a faster
            # way?
            hop.reverse_path = fetch_historical_revtr(src, hop.ip)
        end

        historical_revtr = fetch_historical_revtr(src, dst)

        # maybe not threadsafe, but fukit
        tr_time = Time.new
        measurement_times << ["tr_time", tr_time]
        tr = issue_normal_traceroutes(src, [dst])[dst]

        if tr.empty?
            $LOG.puts "empty traceroute! (#{src}, #{dst})"
            sleep 10
            tr_time2 = Time.new
            tr = issue_normal_traceroutes(src, [dst])[dst]
            $LOG.puts "still empty! (#{src}, #{dst})" if tr.empty?
            results = `ssh uw_revtr2@#{src} 'date; ps aux; sudo traceroute -I #{dst}'`
            Emailer.deliver_isolation_exception("empty traceroute! (#{src}, #{dst})\nFirst tr: #{tr_time.getgm}\nSecond tr:#{tr_time2.getgm}\n#{results}")
        end

        measurements_reissued = false

        if paths_diverge?(src, dst, spoofed_tr, tr)
            # path divergence!
            # reissue traceroute and spoofed traceroute until they don't
            # diverge
            measurements_reissued = 1

            3.times do 
                sleep 30
                tr = issue_normal_traceroutes(src, [dst])[dst]
                @spoof_tr_mutex.synchronize do
                    spoofed_tr = issue_spoofed_traceroutes({[src,dst] => spoofers_w_connectivity})[[src,dst]]
                end

                break if !paths_diverge?(src, dst, spoofed_tr, tr)
                measurements_reissued += 1
            end
        end

        # We would like to know whether the hops on the historicalfoward/reverse/historicalreverse paths
        # are pingeable from the source.
        measurement_times << ["non-revtr pings", Time.new]
        ping_responsive, non_responsive_hops = issue_pings(src, dst, historical_tr, spoofed_tr, historical_revtr)

        if ping_responsive.empty?
            $LOG.puts "empty pings! (#{src}, #{dst})"
            sleep 10
            ping_responsive, non_responsive_hops = issue_pings(src, dst, historical_tr, spoofed_tr, historical_revtr)
            $LOG.puts "still empty! (#{src}, #{dst})" if ping_responsive.empty?
            results = `ssh uw_revtr2@#{src} 'ps aux; ping -c 3 #{FailureIsolation::TestPing}'` 
            Emailer.deliver_isolation_exception("empty pings! (#{src}, #{dst})\n#{results}")
        end

        measurement_times << ["pings_to_nonresponsive_hops", Time.new]
        check_pingability_from_other_vps!(spoofers_w_connectivity, non_responsive_hops)

        if direction != Direction::REVERSE and direction != Direction::BOTH and !testing
            measurement_times << ["revtr", Time.new]
            spoofed_revtr = issue_spoofed_revtr(src, dst, historical_tr.map { |hop| hop.ip })
        else
            spoofed_revtr = SpoofedReversePath.new
        end

        if spoofed_revtr.valid?
           measurement_times << ["revtr pings", Time.new]
           revtr_ping_responsive, revtr_non_responsive_hops = issue_pings_for_revtr(src, spoofed_revtr)
           ping_responsive |= revtr_ping_responsive
        end

        measurement_times << ["measurements completed", Time.new]

        fetch_historical_pingability!(historical_tr, spoofed_tr, spoofed_revtr, historical_revtr)

        dataset = FailureIsolation::get_dataset(dst)
        
        suspected_failure = @failure_analyzer.identify_fault(src, dst, direction, tr, spoofed_tr,
                                                             historical_tr, spoofed_revtr, historical_revtr)

        as_hops_from_src = @failure_analyzer.as_hops_from_src(suspected_failure, tr, spoofed_tr, historical_tr)
        as_hops_from_dst = @failure_analyzer.as_hops_from_dst(suspected_failure, historical_revtr, spoofed_revtr,
                                                spoofed_tr, tr, as_hops_from_src)

        working_historical_paths = @failure_analyzer.find_alternate_paths(src, dst, direction, tr,
                                                    spoofed_tr, historical_tr, spoofed_revtr, historical_revtr)

        measured_working_direction = @failure_analyzer.measured_working_direction?(direction, spoofed_revtr)

        path_changed = @failure_analyzer.path_changed?(historical_tr, tr, spoofed_tr, direction)

        # now... if we found any pingable hops beyond the failure... send
        # traceroutes to them... their paths must differ somehow
        additional_traceroutes = measure_traces_to_pingable_hops(src, suspected_failure, direction, historical_tr, spoofed_revtr,
                                                                 historical_revtr)
        
        [direction, historical_tr, historical_trace_timestamp, spoofed_revtr, historical_revtr,
            ping_responsive, tr, dataset, suspected_failure, as_hops_from_dst, as_hops_from_src, 
            working_historical_paths, measured_working_direction, path_changed, additional_traceroutes, measurements_reissued]
    end

    def measure_traces_to_pingable_hops(src, suspected_failure, direction, 
                                        historical_tr, spoofed_revtr, historical_revtr)
        pingable_targets = []

        if direction == Direction::FORWARD or direction == Direction::BOTH
            pingable_targets += historical_tr.find_all { |hop| hop.ttl > suspected_failure.ttl && hop.ping_responsive }
        end

        pingable_targets += historical_revtr.all_hops_adjacent_to_dst_as.find_all { |hop| hop.ping_responsive }
        pingable_targets += spoofed_revtr.all_hops_adjacent_to_dst_as.find_all { |hop| hop.ping_responsive }

        targ2trace = issue_normal_traceroutes(src, pingable_targets)

        targ2trace
    end

    def generate_jpg(log_name, src, dst, direction, dataset, tr, spoofed_tr, historical_tr, spoofed_revtr,
                             historical_revtr, additional_traceroutes)
        # TODO: put this into its own function
        jpg_output = "#{FailureIsolation::DotFiles}/#{log_name}.jpg"

        Dot::generate_jpg(src, dst, direction, dataset, tr, spoofed_tr, historical_tr, spoofed_revtr,
                             historical_revtr, additional_traceroutes, jpg_output)

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

    def fetch_historical_revtr(src,dst)
        #$LOG.puts "fetch_historical_revtr(#{src}, #{dst})"

        dst = dst.ip if dst.is_a?(Hop)

        path = @revtr_cache.get_cached_reverse_path(src, dst)
        
        # XXX HACKKK. we want to print bad cache results in our email, which takes
        # on an array of hacky non-valid ReverseHop objects...
        path = path.to_s.split("\n").map { |x| ReverseHop.new(x, @ipInfo) } unless path.valid?

        HistoricalReversePath.new(path)
    end

    def retrieve_historical_tr(src, dst)
        if @node2target2trace.include? src and @node2target2trace[src].include? dst
            historical_tr_ttlhoptuples = @node2target2trace[src][dst]
            historical_trace_timestamp = @historical_trace_timestamp
        else
            historical_tr_ttlhoptuples = []
            historical_trace_timestamp = nil
        end

        #$LOG.puts "isolate_outage(#{src}, #{dst}), historical_traceroute_results: #{historical_tr_ttlhoptuples.inspect}"

        # XXX why is this a nested array?
        [ForwardPath.new(historical_tr_ttlhoptuples.map { |ttlhop| HistoricalForwardHop.new(ttlhop[0], ttlhop[1], @ipInfo) }),
            historical_trace_timestamp]
    end

    def issue_pings_towards_srcs(srcdst2stillconnected)
        # hash is target2receiver2succesfulvps
        spoofed_ping_results = @registrar.receive_batched_spoofed_pings(srcdst2stillconnected)

        #$LOG.puts "issue_pings_towards_srcs, spoofed_ping_results: #{spoofed_ping_results.inspect}"

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
                srcdst2spoofed_tr[srcdst] = ForwardPath.new
            else
                srcdst2spoofed_tr[srcdst] = ForwardPath.new(srcdst2sortedttlrtrs[srcdst].map do |ttlrtrs|
                    SpoofedForwardHop.new(ttlrtrs, @ipInfo) 
                end)
            end
        end

        srcdst2spoofed_tr
    end

    # precondition: targets is a single element array
    def issue_normal_traceroutes(src, targets)
        dest2ttlhoptuples = @registrar.traceroute(src, targets, true)

        # THIS PARSING SHOULD BE DONE DIRECTLY IN traceroute.rb YOU NIMKUMPOOP!!!
        targ2paths = {}

        targets.each do |targ|
            if dest2ttlhoptuples.nil? || dest2ttlhoptuples[targ].nil?
                targ2paths[targ] = ForwardPath.new
            else
                targ2paths[targ] = ForwardPath.new(dest2ttlhoptuples[targ].map {|ttlhop| ForwardHop.new(ttlhop, @ipInfo)})
            end
        end

        targ2paths 
    end

    # XXX change me later to deal with revtrs from forward hops
    def issue_spoofed_revtr(src, dst, historical_hops)
        srcdst2revtr = {}
        begin
                srcdst2revtr = (historical_hops.empty?) ? @rtrSvc.get_reverse_paths([[src, dst]]) :
                                                          @rtrSvc.get_reverse_paths([[src, dst]], [historical_hops])
        rescue DRb::DRbConnError => e
            connect_to_drb()
            return SpoofedReversePath.new([:drb_connection_refused])
        rescue Exception, NoMethodError => e
            Emailer.deliver_isolation_exception("#{e} \n#{e.backtrace.join("<br />")}") 
            connect_to_drb()
            return SpoofedReversePath.new([:drb_exception])
        rescue Timeout::Error
            return SpoofedReversePath.new([:self_induced_timeout])
        end

        #$LOG.puts "isolate_outage(#{src}, #{dst}), srcdst2revtr: #{srcdst2revtr.inspect}"

        raise "issue_spoofed_revtr returned an #{srcdst2revtr.class}!" unless srcdst2revtr.is_a?(Hash)

        if srcdst2revtr.nil? || srcdst2revtr[[src,dst]].nil?
            return SpoofedReversePath.new([:nil_return_value])
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
        
        SpoofedReversePath.new(spoofed_revtr)
    end

    # We would like to know whether the hops on the historicalfoward/reverse/historicalreverse paths
    # are pingeable from the source. Send pings, update
    # hop.ping_responsive, and return the responsive pings
    def issue_pings(source, dest, historical_tr, spoofed_tr, historical_revtr)
        all_hop_sets = [[Hop.new(dest), Hop.new(FailureIsolation::TestPing)], historical_tr, spoofed_tr, historical_revtr]

        for hop in historical_tr
            all_hop_sets << hop.reverse_path if !hop.reverse_path.nil? and hop.reverse_path.valid?
        end

        request_pings(source, all_hop_sets)
    end

    # we issue the pings separately for the revtr, since the revtr can take an
    # excrutiatingly long time to execute sometimes
    def issue_pings_for_revtr(source, revtr)
        if revtr.valid?
           return request_pings(source, [revtr]) 
        else
           return [[], []]
        end
    end

    # private
    def request_pings(source, all_hop_sets)
        all_targets = Set.new
        all_hop_sets.each { |hops| all_targets |= (hops.map { |hop| hop.ip }) }

        responsive = @registrar.ping(source, all_targets.to_a, true)
        responsive ||= []
        #$LOG.puts "Responsive to ping: #{responsive.inspect}"

        # update reachability
        all_hop_sets.each do |hop_set|
            hop_set.each { |hop| hop.ping_responsive = responsive.include? hop.ip }
        end

        unresponsive_ips = all_targets - responsive
        unresponsive_hops = Set.new
        all_hop_sets.each do |hop_set|
            unresponsive_hops |= hop_set.find_all { |hop| unresponsive_ips.include?(hop.ip) }
        end

        [responsive, unresponsive_hops]
    end

    def check_pingability_from_other_vps!(connected_vps, non_responsive_hops)
        # there might be multiple hops with the same ip, so we can't have a
        # nice hashmap from ips -> hops
        targets = non_responsive_hops.map { |hop| hop.ip }

        pingable_ips = Set.new

        # TODO: thread out
        connected_vps.each do |vp|
            pingable_ips |= @registrar.ping(vp, targets, true)
        end

        non_responsive_hops.each do |hop|
            hop.reachable_from_other_vps = pingable_ips.include? hop.ip
        end
    end

    # XXX Am I giving Ethan all of these hops properly?
    def fetch_historical_pingability!(historical_tr, spoofed_tr, spoofed_revtr, historical_revtr)
        # TODO: redundannnnttt
        all_hop_sets = [historical_tr, spoofed_tr, historical_revtr]

        for hop in historical_tr
            if !(hop.reverse_path.nil?) && hop.reverse_path.valid?
                all_hop_sets << hop.reverse_path 
            end
        end

        all_hop_sets << spoofed_revtr if spoofed_revtr.valid? # might contain a symbol. hmmm... XXX
        all_targets = Set.new
        all_hop_sets.each { |hops| all_targets |= (hops.map { |hop| hop.ip }) }

        ip2lastresponsive = @db.fetch_pingability(all_targets.to_a)

        #$LOG.puts "fetch_historical_pingability(), ip2lastresponsive #{ip2lastresponsive.inspect}"

        # update historical reachability
        all_hop_sets.each do |hop_set|
            hop_set.each { |hop| hop.last_responsive = ip2lastresponsive[hop.ip] }
        end
    end

    def get_uniq_filename(src, dst)
        t = Time.new
        t_str = t.strftime("%Y%m%d%H%M%S")
        "#{src}_#{dst}_#{t_str}"
    end

    # see outage.rb
    def log_isolation_results(outage)
        filename = outage.file
        File.open(FailureIsolation::IsolationResults+"/"+filename+".bin", "w") { |f| f.write(Marshal.dump(outage)) }
    end
end
