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
require 'outage'
require 'utilities'

# This guy is just in charge of issuing measurements and logging/emailing results
#
# TODO: log additional traceroutes
# TODO: make use of logger levels so we don't have to comment out log
# statements
class FailureDispatcher
    attr_accessor :node_2_failed_measurements  # assume that the size of this field is constant

    def initialize(db=DatabaseInterface.new, logger=LoggerLog.new($stderr))
        @logger = logger
        @controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
        @registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)

        acl=ACL.new(%w[deny all
					allow *.cs.washington.edu
					allow localhost
					allow 127.0.0.1
					])

        @drb_mutex = Mutex.new
        @spoof_tr_mutex = Mutex.new

        connect_to_drb() # sets @rtrSvc
        @have_retried_connection = false # so that multiple threads don't try to reconnect to DRb

        @ipInfo = IpInfo.new

        @failure_analyzer = FailureAnalyzer.new(@ipInfo)
        
        @db = db

        @revtr_cache = RevtrCache.new(@db, @ipInfo)

        # track when nodes fail to return tr or ping results
        @node_2_failed_measurements = Hash.new(0)

        @dot_generator = DotGenerator.new(@logger)

        Thread.new do
            loop do
                @historical_trace_timestamp, @node2target2trace = YAML.load_file FailureIsolation::HistoricalTraces
                sleep 60 * 60 * 24
            end
        end
    end

    def connect_to_drb()
        @drb_mutex.synchronize do
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
    def isolate_outages(srcdst2outage, dst2outage_correlation, testing=false) # this testing flag is terrrrible
        @have_retried_connection = false

        # first filter out any outages where no nodes are actually registered
        # with the controller
        @logger.puts "before filtering, srcdst2outage: #{srcdst2outage.inspect}"
        registered_vps = @controller.hosts.clone
        srcdst2outage.delete_if do |srcdst, outage|
            if !registered_vps.include?(srcdst[0])
               @logger.info "source #{srcdst[0]} not registered."
               return true
            elsif (registered_vps & outage.receivers).empty?
               @logger.info "registered_vps & outage.receivers #{outage.receivers} empty"
               return true
            end
            return false
        end
        @logger.puts "after filtering, srcdst2outage: #{srcdst2outage.inspect}"

        return if srcdst2outage.empty? # optimization

        measurement_times = []

        # ================================================================================
        # We issue spoofed pings/traces globally to avoid race conditions over spoofer   #
        # ids
        # ================================================================================
       
        # quickly isolate the directions of the failures
        measurement_times << ["spoof_ping", Time.new]
        issue_pings_towards_srcs(srcdst2outage)
        @logger.debug("pings towards source issued")

        # if we control one of the targets, (later) send out spoofed traceroutes in
        # the opposite direction for ground truth information
        dstsrc2outage = check4targetswecontrol(srcdst2outage, registered_vps)
        @logger.debug("dstsrc2outage: " + dstsrc2outage.inspect)

        # we check the forward direction by issuing spoofed traceroutes (rather than pings)
        measurement_times << ["spoof_tr", Time.new]
        issue_spoofed_traceroutes(srcdst2outage, dstsrc2outage)
        @logger.debug("spoofed traceroute issued")

        # thread out on each src, dst
        srcdst2outage.each do |srcdst, outage|
            Thread.new do
                src,dst = srcdst
                outage.measurement_times = deep_copy(measurement_times)
                analyze_results(outage, dst2outage_correlation[dst], testing)
            end
        end
    end

    # private

    def check4targetswecontrol(srcdst2outage, registered_hosts)
       dstsrc2outage = {}

       srcdst2outage.each do |srcdst, outage|
            src, dst = srcdst
            if FailureIsolation::SpooferTargets.include? dst
                dst_hostname = FailureIsolation::SpooferIP2Hostname[dst]
                @logger.puts "check4targetswecontrol: dst ip is: #{dst}, dst_hostname is: #{dst_hostname}. ip mismap?"

                if registered_hosts.include? dst_hostname
                    outage.symmetric = true
                    # XXX Possible problem with ip2hostname mappings??
                    outage.src_ip = $pl_host2ip[src]
                    outage.dst_hostname = dst_hostname
                    dstsrc2outage[[outage.dst_hostname, outage.src_ip]] = outage
                end
            end
       end

       dstsrc2outage
    end

    def analyze_results(outage, outage_correlation, testing=false)
        @logger.debug "analyze_results: #{outage.src}, #{outage.dst}"

        gather_additional_data(outage, testing)

        outage.file = get_uniq_filename(outage.src, outage.dst)

        outage.passed_filters, reasons = @failure_analyzer.passes_filtering_heuristics?(outage.src, outage.dst, outage.tr, outage.spoofed_tr,
                                                             outage.ping_responsive, outage.historical_tr, outage.historical_revtr, 
                                                             outage.direction, testing)

        @logger.debug "analyze_results: #{outage.src}, #{outage.dst}, passed_filters: #{outage.passed_filters}"

        outage.build

        if(!testing)
            log_isolation_results(outage)
        end

        if(outage.passed_filters)
            outage_correlation.final_passed << outage.src
        else
            outage_correlation.final_failed2reasons[outage.src] = reasons
        end

        # XXX thread safe? I doubt it...
        if outage_correlation.complete?
           log_outage_correlation(outage_correlation) 
           @logger.debug("logged outage correlation")
        end

        if(outage.passed_filters)
            outage.jpg_output = generate_jpg(outage.log_name, outage.src, outage.dst, outage.direction, outage.dataset, 
                             outage.tr, outage.spoofed_tr, outage.historical_tr, outage.spoofed_revtr,
                             outage.historical_revtr, outage.additional_traceroutes, outage.upstream_reverse_paths)

            outage.graph_url = generate_web_symlink(outage.jpg_output)

            # TODO: make deliver_isolation_results polymorphic for
            #       symmetric outages
            Emailer.deliver_isolation_results(outage, testing)

            @logger.puts "Attempted to send isolation_results email for #{outage.src} #{outage.dst} testing #{testing}..."
        else
            @logger.puts "Heuristic failure! measurement times: #{outage.measurement_times.inspect}"
        end

        return outage.passed_filters
    end

    # TODO: I should figure out a better way to gather data, rather
    # than this longgg method
    def gather_additional_data(outage, testing)
        reverse_problem = outage.pings_towards_src.empty?
        forward_problem = !outage.spoofed_tr.reached?(outage.dst)

        outage.direction = @failure_analyzer.infer_direction(reverse_problem, forward_problem)
        @logger.debug("direction: " + outage.direction)

        # HistoricalForwardHop objects
        outage.historical_tr, outage.historical_trace_timestamp = retrieve_historical_tr(outage.src, outage.dst)

        outage.historical_tr.each do |hop|
            # thread out on this to make it faster? Ask Dave for a faster
            # way?
            hop.reverse_path = fetch_historical_revtr(outage.src, hop.ip)
        end

        outage.historical_revtr = fetch_historical_revtr(outage.src, outage.dst)

        @logger.debug "historical paths fetched"

        # maybe not accurate given multiple threads, but fukit
        tr_time = Time.new
        outage.measurement_times << ["tr_time", tr_time]
        outage.tr = issue_normal_traceroutes(outage.src, [outage.dst])[outage.dst]

        @logger.debug "traceroutes issued"

        if outage.tr.empty?
            @logger.warn "empty traceroute! #{outage.src} #{outage.dst}"
            restart_atd(outage.src)
            sleep 10
            tr_time2 = Time.new
            outage.tr = issue_normal_traceroutes(outage.src, [outage.dst])[outage.dst]
            if outage.tr.empty?
                @logger.puts "still empty! (#{outage.src}, #{outage.dst})" 
                @node_2_failed_measurements[outage.src] += 1
            end
        end

        measurements_reissued = false

        if outage.paths_diverge?
            # path divergence!
            # reissue traceroute and spoofed traceroute until they don't
            # diverge
            measurements_reissued = 1

            3.times do 
                sleep 30
                outage.tr = issue_normal_traceroutes(outage.src, [outage.dst])[outage.dst]
                issue_spoofed_traceroutes({[src,dst] => outage})

                break if !outage.paths_diverge?
                measurements_reissued += 1
            end
        end

        # TODO: implement retries for symmetric traceroutes?

        # We would like to know whether the hops on the historicalfoward/reverse/historicalreverse paths
        # are pingeable from the source.
        outage.measurement_times << ["non-revtr pings", Time.new]
        ping_responsive, non_responsive_hops = check_reachability(outage)

        @logger.debug "non-revtr pings issued"

        if ping_responsive.empty?
            @logger.puts "empty pings! (#{outage.src}, #{outage.dst})"
            restart_atd(outage.src)
            sleep 10
            ping_responsive, non_responsive_hops = check_reachability(outage)
            if ping_responsive.empty?
                @logger.puts "still empty! (#{outage.src}, #{outage.dst})" 
                @node_2_failed_measurements[outage.src] += 1
            end
        end

        outage.measurement_times << ["pings_to_nonresponsive_hops", Time.new]
        check_pingability_from_other_vps!(outage.formatted_connected, non_responsive_hops)

        @logger.debug "pings to non-responsive hops issued"

        if outage.direction != Direction::REVERSE and outage.direction != Direction::BOTH and !testing
            outage.measurement_times << ["revtr", Time.new]
            outage.spoofed_revtr = issue_revtr(outage.src, outage.dst, outage.historical_tr.map { |hop| hop.ip })
        else
            outage.spoofed_revtr = SpoofedReversePath.new
        end

        @logger.debug "spoofed_revtr issued"

        if outage.spoofed_revtr.valid?
           outage.measurement_times << ["revtr pings", Time.new]
           revtr_ping_responsive, revtr_non_responsive_hops = issue_pings_for_revtr(outage.src, outage.spoofed_revtr)
           ping_responsive |= revtr_ping_responsive

           @logger.debug "revtr pings issued"
        end

        outage.measurement_times << ["measurements completed", Time.new]

        fetch_historical_pingability!(outage)

        @logger.debug "historical pingability fetched"

        outage.suspected_failure = @failure_analyzer.identify_fault(outage.src, outage.dst, outage.direction, outage.tr, 
                                                             outage.spoofed_tr, outage.historical_tr, outage.spoofed_revtr,
                                                             outage.historical_revtr)

        outage.as_hops_from_src = @failure_analyzer.as_hops_from_src(outage.suspected_failure, outage.tr, outage.spoofed_tr, outage.historical_tr)
        outage.as_hops_from_dst = @failure_analyzer.as_hops_from_dst(outage.suspected_failure, outage.historical_revtr, outage.spoofed_revtr,
                                                outage.spoofed_tr, outage.tr, outage.as_hops_from_src)

        outage.alternate_paths = @failure_analyzer.find_alternate_paths(outage.src, outage.dst, outage.direction, outage.tr,
                                                    outage.spoofed_tr, outage.historical_tr, outage.spoofed_revtr, outage.historical_revtr)

        outage.measured_working_direction = @failure_analyzer.measured_working_direction?(outage.direction, outage.spoofed_revtr)

        outage.path_changed = @failure_analyzer.path_changed?(outage.historical_tr, outage.tr, outage.spoofed_tr, outage.direction)

        # now... if we found any pingable hops beyond the failure... send
        # traceroutes to them... their paths must differ somehow
        outage.additional_traces = measure_traces_to_pingable_hops(outage.src, outage.suspected_failure, outage.direction, outage.historical_tr, 
                                                                   outage.spoofed_revtr, outage.historical_revtr)

        # TODO: an upstream router in a reverse traceroute at the reachability
        # horizon: was there a path change? Issue spoofed reverse traceroute,
        # and compare to historical reverse traceroute.
        if(outage.direction == Direction::REVERSE && outage.historical_revtr.valid? && !outage.suspected_failure.nil? &&
               !outage.suspected_failure.next.nil? && outage.suspected_failure.next.ping_responsive)
            # TODO: should the key be the ip, or the Hop object?
           upstream_revtr = issue_revtr(outage.src, outage.suspected_failure.next.ip) # historical traceroute?
           outage.upstream_reverse_paths = {suspected_failure.next.ip => upstream_revtr}
           @logger.debug("upstream revtr issued")
        end

        if outage.symmetric
            outage.dst_tr = issue_normal_traceroutes(outage.dst_hostname, [outage.src_ip])[outage.src_ip]
            @logger.debug("destination's tr issued. valid?:#{outage.dst_tr.valid?}")

            splice_alternate_paths(outage)
            @logger.debug("alternate path splicing complete")
        end
    end

    # TODO: move me into a VP object
    def restart_atd(vp)
        system "ssh uw_revtr2@#{vp} 'killall atd; sleep 1; sudo /sbin/service atd start > /dev/null 2>&1"
    end

    def generate_jpg(log_name, src, dst, direction, dataset, tr, spoofed_tr, historical_tr, spoofed_revtr,
                             historical_revtr, additional_traceroutes, upstream_reverse_paths)
        # TODO: put this into its own function
        jpg_output = "#{FailureIsolation::DotFiles}/#{log_name}.jpg"

        @dot_generator.generate_jpg(src, dst, direction, dataset, tr, spoofed_tr, historical_tr, spoofed_revtr,
                             historical_revtr, additional_traceroutes, upstream_reverse_paths, jpg_output)

        jpg_output
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

    def measure_traces_to_pingable_hops(src, suspected_failure, direction, 
                                        historical_tr, spoofed_revtr, historical_revtr)
        return {} if suspected_failure.nil?

        pingable_targets = @failure_analyzer.pingable_hops_beyond_failure(src, suspected_failure, direction, historical_tr)
        pingable_targets |= @failure_analyzer.pingable_hops_near_destination(src, historical_tr, spoofed_revtr, historical_revtr)

        pingable_targets.map! { |hop| hop.ip }

        @logger.debug "pingable_targets, #{Time.now} #{pingable_targets.inspect}"

        targ2trace = issue_normal_traceroutes(src, pingable_targets)

        targ2trace
    end

    def fetch_historical_revtr(src,dst)
        @logger.debug "fetch_historical_revtr(#{src}, #{dst})"

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

        @logger.debug "isolate_outage(#{src}, #{dst}), historical_traceroute_results: #{historical_tr_ttlhoptuples.inspect}"

        # XXX why is this a nested array?
        [ForwardPath.new(historical_tr_ttlhoptuples.map { |ttlhop| HistoricalForwardHop.new(ttlhop[0], ttlhop[1], @ipInfo) }),
            historical_trace_timestamp]
    end

    def issue_pings_towards_srcs(srcdst2outage)
        # hash is target2receiver2succesfulvps
        spoofed_ping_results = @registrar.receive_batched_spoofed_pings(srcdst2outage.map_values { |outage| outage.receivers })

        @logger.debug "issue_pings_towards_srcs, spoofed_ping_results: #{spoofed_ping_results.inspect}"

        srcdst2outage.each do |srcdst, outage|
            src, dst = srcdst
            if spoofed_ping_results.nil? || spoofed_ping_results[dst].nil? || spoofed_ping_results[dst][src].nil?
                outage.pings_towards_src = []
            else
                outage.pings_towards_src = spoofed_ping_results[dst][src]
            end
        end
    end

    def issue_spoofed_traceroutes(srcdst2outage, dstsrc2outage={})
        @spoof_tr_mutex.synchronize do
            # for symmetric outages
            merged_srcdst2outage = dstsrc2outage.merge(srcdst2outage)
            # TODO: add in the other node as the receiver, since we have
            # control over it?

            srcdst2sortedttlrtrs = @registrar.batch_spoofed_traceroute(
                                                merged_srcdst2outage.map_values { |outage| outage.receivers })

            srcdst2outage.each do |srcdst, outage|
                outage.spoofed_tr = retrieve_spoofed_tr(srcdst, srcdst2sortedttlrtrs)
            end

            dstsrc2outage.each do |dstsrc, outage|
                outage.dst_spoofed_tr = retrieve_spoofed_tr(dstsrc, srcdst2sortedttlrtrs)
            end
        end
    end

    def retrieve_spoofed_tr(srcdst, srcdst2sortedttlrtrs)
        if srcdst2sortedttlrtrs.nil? || srcdst2sortedttlrtrs[srcdst].nil?
            path = ForwardPath.new
        else
            path = ForwardPath.new(srcdst2sortedttlrtrs[srcdst].map do |ttlrtrs|
                SpoofedForwardHop.new(ttlrtrs, @ipInfo) 
            end)
        end

        path
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

    def issue_revtr(src, dst, historical_hops=[], spoofed=true)
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

        @logger.debug "isolate_outage(#{src}, #{dst}), srcdst2revtr: #{srcdst2revtr.inspect}"

        raise "issue_revtr returned an #{srcdst2revtr.class}: #{srcdst2revtr.inspect}!" unless srcdst2revtr.is_a?(Hash) or srcdst2revtr.is_a?(DRb::DRbObject)

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

        @logger.debug "isolate_outage(#{src}, #{dst}), spoofed_revtr: #{spoofed_revtr.inspect}"
        
        SpoofedReversePath.new(spoofed_revtr)
    end

    # We would like to know whether the hops on the historicalfoward/reverse/historicalreverse paths
    # are pingeable from the source. Send pings, update
    # hop.ping_responsive, and return the responsive pings
    def check_reachability(outage)
        all_hop_sets = [[Hop.new(outage.dst), Hop.new(FailureIsolation::TestPing)], outage.historical_tr, outage.spoofed_tr, outage.historical_revtr]

        for hop in outage.historical_tr
            all_hop_sets << hop.reverse_path if !hop.reverse_path.nil? and hop.reverse_path.valid?
        end

        request_pings(outage.src, all_hop_sets)
    end

    # all pairs
    def issue_pings(srcs, dsts)
        @registrar.all_pairs_ping(srcs,dsts)
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
        @logger.debug "Responsive to ping: #{responsive.inspect}"

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

        # there might be multiple hops with the same ip, so we can't have a
        # nice hashmap from ips -> hops
        targets = non_responsive_hops.map { |hop| hop.ip }

        src2reachable = @registrar.all_pairs_ping(connected_vps, targets)
        pingable_ips = src2reachable.value_set.to_a

        non_responsive_hops.each do |hop|
            hop.reachable_from_other_vps = pingable_ips.include? hop.ip
        end
    end

    # 2. In the intro, we claim that routing problems where
    # a working policy-compliant path exists, but networks
    # instead route along a different path that fails to deliver
    # packets. are common. It would be nice to
    # have a killer demonstration of this. I.m not positive
    # what it would be, beyond actually making the
    # whole system work and finding the working paths
    # in the case of a failure (this is listed in x5.0.3).
    # Dave suggests that unidirectional failures are such
    # a case. To me, it seems like there could be an issue
    # that kept a link/router from working in only
    # one direction. We are going to investigate splicing
    # together possible paths from 2 known working
    # sub-paths (iPlane-style). Initially, we will investigate
    # this in cases when we control both S and
    # D. For a possible alternate path, we will find the
    # first AS that diverges from the actual path, then
    # identify the ingress router R on that possible path.
    # We will then check if S and D can both ping R. If
    # they can, we will check if the path via R is policycompliant.
    # To generate these detour paths, we can
    # look at the working direction in unidirectional failures,
    # the paths taken by VPs that have connectivity,
    # historical paths from the failing VP, or possibly
    # iPlane predictions. We do not yet have a way to
    # check this if we only control one endpoint. Loose
    # source routing option would do it, but is filtering
    # widely.
    #
    # pre: outage.symmetric == true
    def splice_alternate_paths(outage)
       raise "not a symmetric outage!" unless outage.symmetric

       if outage.direction == Direction::FORWARD
          # TODO: use other data for finding ingresses
          return if outage.tr.empty? # spooftr
          return if outage.historical_tr.empty?
          current_as_path = outage.tr.compressed_as_path  # spooftr?
          old_as_path = outage.historical_tr.compressed_as_path

          divergent_as = Path.first_point_of_divergence(old_as_path, current_as_path)
          return if divergent_as.nil?

          ingress = outage.historical_tr.ingress_router_to_as(divergent_as)
          return if ingress.nil?

          # ping ingress from s and d
          @logger.debug "splice_alternate_paths() issuing pings"
          src2reachable = issue_pings([outage.src, outage.dst_hostname], [ingress.ip])
          @logger.debug "src2reachable: #{src2reachable.inspect}"
          
          return if !(src2reachable[outage.src].include? ingress.ip and src2reachable[outage.dst_hostname].include? ingress.ip)

          @logger.debug "splice_alternate_paths() ingress router reachable"

          src_trace_to_ingress = issue_normal_traceroutes(outage.src, [ingress.ip])[ingress.ip]
          @logger.debug "normal trace: #{src_trace_to_ingress}"
          return unless src_trace_to_ingress.valid?
          # TODO: normal revtr
          dst_revtr_from_ingress = issue_revtr(outage.dst_hostname, ingress.ip, [], false)
          @logger.debug "dst revtr: #{dst_revtr_from_ingress}"
          return unless dst_revtr_from_ingress.valid?

          outage.spliced_paths << SplicedPath.new(outage.src, outage.dst_hostname, ingress, src_trace_to_ingress, dst_revtr_from_ingress)

          # TODO check if path is policy-compliant
       else
         # src = outage.dst_hostname
         # dst = outage.src_ip
       end
    end

    # XXX Am I giving Ethan all of these hops properly?
    def fetch_historical_pingability!(outage)
        all_hop_sets = [outage.historical_tr, outage.spoofed_tr, outage.historical_revtr]

        for hop in outage.historical_tr
            if !(hop.reverse_path.nil?) && hop.reverse_path.valid?
                all_hop_sets << hop.reverse_path 
            end
        end

        all_hop_sets << outage.spoofed_revtr if outage.spoofed_revtr.valid? # might contain a symbol. hmmm... XXX
        all_targets = Set.new
        all_hop_sets.each { |hops| all_targets |= (hops.map { |hop| hop.ip }) }

        ip2lastresponsive = @db.fetch_pingability(all_targets.to_a)

        @logger.debug "fetch_historical_pingability(), ip2lastresponsive #{ip2lastresponsive.inspect}"

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

    def log_outage_correlation(outage_correlation)
        t = Time.new
        t_str = t.strftime("%Y%m%d%H%M%S")
        filename = "#{outage_correlation.target}_#{t_str}.yml"
        File.open(FailureIsolation::OutageCorrelation+"/"+filename, "w") { |f| YAML.dump(outage_correlation, f) }
    end
end
