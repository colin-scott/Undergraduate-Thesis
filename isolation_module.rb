#!/homes/network/revtr/ruby/bin/ruby

require 'drb'
require 'drb/acl'
require 'net/http'
require 'mail'
require 'set'
require 'yaml'
require 'time'
require 'fileutils'
require 'thread'
require 'reverse_traceroute_cache'
require 'ip_info'
require 'mkdot'
require 'hops'
require 'db_interface'
require 'base64'
require '../spooftr_config.rb' # XXX don't hardcode...

# XXX Don't hardcode!!!
$pptasks = "~ethan/scripts/pptasks"
$default_period_seconds = 620
Thread.abort_on_exception = true

module FailureIsolation
    # out of place...
    FailureIsolation::ControllerUri = IO.read("#{$DATADIR}/uris/controller.txt").chomp
    FailureIsolation::RegistrarUri = IO.read("#{$DATADIR}/uris/registrar.txt").chomp

    # XXX terrible terrible
    FailureIsolation::CloudfrontTargets = Set.new([ "204.246.165.221", "204.246.169.63", "216.137.33.1",
        "216.137.35.21", "216.137.37.156", "216.137.39.152", "216.137.41.78",
        "216.137.43.189", "216.137.45.33", "216.137.47.127", "216.137.53.96",
        "216.137.55.170", "216.137.57.207", "216.137.59.4", "216.137.61.174",
        "216.137.63.221" ])

    FailureIsolation::TargetSet = "/homes/network/revtr/spoofed_traceroute/current_target_set.txt"

    FailureIsolation::PingMonitorState = "~/colin/target_state.yml"
    FailureIsolation::PingMonitorRepo = "#{$DATADIR}/ping_monitoring_state/"

    FailureIsolation::MonitoringNodes = "/homes/network/revtr/spoofed_traceroute/cloudfront_spoofing_monitoring_nodes.txt"

    FailureIsolation::MonitorSlice = "uw_revtr2"
    FailureIsolation::IsolationSlice = "uw_revtr" # why do we separate the slices?

    FailureIsolation::RevtrRequests = "/homes/network/revtr/failure_isolation/revtr_requests/current_requests.txt"

    FailureIsolation::HistoricalTraces = "#{$DATADIR}/most_recent_historical_traces.txt"

    FailureIsolation::CachedRevtrTool = "~/dave/revtr-test/reverse_traceroute/print_cached_reverse_path.rb"

    FailureIsolation::TargetBlacklist = "/homes/network/revtr/spoofed_traceroute/target_blacklist.txt"

    def FailureIsolation::read_in_spoofer_hostnames()
       ip2hostname = {}
       File.foreach("#{$DATADIR}/up_spoofers_w_ips.txt") do |line|
          hostname, ip = line.chomp.split  
          ip2hostname[ip] = hostname
       end
       ip2hostname
    end

    FailureIsolation::DataSetDir = "/homes/network/revtr/spoofed_traceroute/datasets"
    # targets taken from Harsha's most well connected PoPs
    FailureIsolation::HarshaPoPs = Set.new(IO.read("#{FailureIsolation::DataSetDir}/responsive_corerouters.txt").split("\n"))
    # targets taken from routers on paths beyond Harsha's most well connected PoPs
    FailureIsolation::BeyondHarshaPoPs = Set.new(IO.read("#{FailureIsolation::DataSetDir}/responsive_edgerouters.txt").split("\n"))
    # targets taken from spoofers.hosts
    FailureIsolation::SpooferTargets = Set.new(IO.read("#{FailureIsolation::DataSetDir}/up_spoofers.ips").split("\n"))
    FailureIsolation::SpooferIP2Hostname = FailureIsolation::read_in_spoofer_hostnames

    FailureIsolation::OutageNotifications = "#{$DATADIR}/outage_notifications"
    FailureIsolation::IsolationResults = "#{$DATADIR}/isolation_results_rev2"
    FailureIsolation::DotFiles = "#{$DATADIR}/dots"
    FailureIsolation::SymmetricIsolationResults = "#{$DATADIR}/symmetric_isolation_results"

    def FailureIsolation::get_dataset(dst)
        if FailureIsolation::HarshaPoPs.include? dst
            return "Harsha's most well-connected PoPs"
        elsif FailureIsolation::BeyondHarshaPoPs.include? dst
            return "Routers on paths beyond Harsha's PoPs"
        elsif FailureIsolation::CloudfrontTargets.include? dst
            return "CloudFront"
        elsif FailureIsolation::SpooferTargets.include? dst
            return "PL/mlab nodes"
        else
            return "Unkown"
        end
    end
end

class FailureMonitor
    def initialize(dispatcher, email="failures@cs.washington.edu")
        @dispatcher = dispatcher
        @email = email

        # TODO: handle these with optparse
        @@minutes_per_round = 2
        @@timestamp_bound = 605
        @@upper_rounds_bound = 120
        @@lower_rounds_bound = 4
        @@vp_bound = 2
        # if more than 70% of a node's targets are unreachable, we ignore the
        # node
        @@source_specific_problem_threshold = 0.35
        # how often we send out faulty_node_audit reports
        @@node_audit_period = 60*60*24 / $default_period_seconds / 3

        @target_set_size = 0

        File.foreach FailureIsolation::TargetSet do |line|
            @target_set_size += 1
        end

        @all_targets = Set.new
        File.foreach(FailureIsolation::TargetSet){ |line| @all_targets.add line.chomp }

        @all_nodes = Set.new
        File.foreach(FailureIsolation::MonitoringNodes){ |line| @all_nodes.add line.chomp }

        @@never_seen_yml = "./targets_never_seen.yml"
        begin
            @vps_2_targets_never_seen = YAML.load_file(@@never_seen_yml)
            raise unless @vps_2_targets_never_seen
        rescue
            @vps_2_targets_never_seen = {}

            # unresponsive until proven otherwise
            File.foreach(FailureIsolation::MonitoringNodes) { |node| @vps_2_targets_never_seen[node.chomp] = @all_targets }
        end
        
        @@last_outage_yml = "./last_outages.yml"
        begin
            # [node, target] -> last time outage was observed
            @nodetarget2lastoutage = (File.readable? @@last_outage_yml) ? YAML.load_file(@@last_outage_yml) : {}
            raise unless @nodetarget2lastoutage.is_a?(Hash)
        rescue
            @nodetarget2lastoutage = {}
        end

        @outdated_nodes = {}
        @problems_at_the_source = {}

        # so that we don't probe the hell out of failed routers
        # target -> time
        @nodetarget2lastisolationattempt = {}
        @@isolation_interval = 6 # we isolate at most every 6*10.33 =~ 60 minutes

        @current_round = 0
    end

    # write out @vps_2_targets_never_seen and
    # @nodetarget2lastoutage to a YAML file to be read in later
    def persist_state
        File.open(@@never_seen_yml, "w") { |f| YAML.dump(@vps_2_targets_never_seen, f) }
        File.open(@@last_outage_yml, "w") { |f| YAML.dump(@nodetarget2lastoutage, f) }
    end

    # infinitely loop, periodically pulling state from ping monitors
    def start_pull_cycle(period)
        FileUtils.mkdir_p(FailureIsolation::PingMonitorRepo) 

        loop do
            @target_blacklist = Set.new(IO.read(FailureIsolation::TargetBlacklist).split("\n"))

            system "#{$pptasks} scp #{FailureIsolation::MonitorSlice} #{FailureIsolation::MonitoringNodes} 100 100 \
                     @:#{FailureIsolation::PingMonitorState} :#{FailureIsolation::PingMonitorRepo}state"

            node2targetstate = read_in_results()

            update_auxiliary_state(node2targetstate)

            target2observingnode2rounds, target2neverseen, target2stillconnected = classify_outages(node2targetstate)
            
            srcdst2stillconnected, srcdst2formatted_connected, srcdst2formatted_unconnected = send_notification(target2observingnode2rounds, target2neverseen, target2stillconnected)

            @dispatcher.isolate_outages(srcdst2stillconnected, srcdst2formatted_connected, srcdst2formatted_unconnected)

            $LOG.puts "round #{@current_round} completed"
            @current_round += 1
            
            audit_faulty_nodes if (@current_round % @@node_audit_period) == 0

            sleep period
        end
    end

    private

    def read_in_results
        current_time = Time.now
        node2targetstate = {}

        @not_sshable = @all_nodes.clone

        Dir.glob("#{FailureIsolation::PingMonitorRepo}state*").each do |yaml|
            # is there a cleaner way to get the mtime of a file?
            input = File.open(yaml)
            mtime = input.mtime
            input.close

            node = yaml.split("state.")[1]

            seconds_difference = (current_time - mtime).abs
            if seconds_difference >= @@timestamp_bound
                minutes_difference = seconds_difference / 60
                @outdated_nodes[node] = minutes_difference
                $LOG.puts "#{node}'s data is #{minutes_difference} minutes out of date"
                next
            end

            @not_sshable.delete node

            # "state.node1.pl.edu"
            begin
                hash = YAML.load_file(yaml)
            rescue
                $LOG.puts "Corrupt YAML file: #{node}"
                next
            end

            if !hash.is_a?(Hash)
                $LOG.puts "#{node}'s data was not a hash!!"
                next
            end

            failure_percentage = hash.size * 1.0 / @target_set_size
            if failure_percentage > @@source_specific_problem_threshold
                @problems_at_the_source[node] = failure_percentage * 100
                $LOG.puts "Problem at the source: #{node}"
                next
            end

            @outdated_nodes.delete node
            @problems_at_the_source.delete node
            node2targetstate[node] = hash
        end

        node2targetstate
    end

    def audit_faulty_nodes()
        Emailer.deliver_faulty_node_report(@outdated_nodes,
                                           @problems_at_the_source,
                                           @not_sshable)
    end

    def update_auxiliary_state(node2targetstate)
        current_time = Time.now

        node2targetstate.each do |node, target_state|
            target_state.keys.each do |target|
                @nodetarget2lastoutage[[node,target]] = current_time
            end

            if !@vps_2_targets_never_seen[node].empty?
                @vps_2_targets_never_seen[node] -= (@all_targets - Set.new(target_state.keys)) 
            end
        end
    end

    def classify_outages(node2targetstate)
        # target -> { node -> # rounds }
        target2observingnode2rounds = Hash.new { |hash,key| hash[key] = {} }
        # target -> [node1, node2, ...]
        target2neverseen = Hash.new { |hash,key| hash[key] = [] }
        # target -> [node1, node2, ...] 
        target2stillconnected = {}

        active_nodes = node2targetstate.keys
        all_targets = Set.new
     
        node2targetstate.each do |node, target_state|
            target_state.each do |target, rounds|
               next if @target_blacklist.include? target
               # XXX For backwards compatibility...
               rounds = rounds[0] if rounds.is_a?(Array)

               if rounds.nil?
                   $LOG.puts "#{node}: #{target} is nil..."
                   next
               end
                
               all_targets.add target

               if !@vps_2_targets_never_seen[node].include? target
                   target2observingnode2rounds[target][node] = rounds
               else 
                   target2neverseen[target] << node
               end
            end
        end

        all_targets.each do |target|
            target2stillconnected[target] = active_nodes - (target2neverseen[target] + target2observingnode2rounds[target].keys)
        end

        [target2observingnode2rounds, target2neverseen, target2stillconnected]
    end

    def send_notification(target2observingnode2rounds, target2neverseen, target2stillconnected)
        formatted_problems_at_the_source = @problems_at_the_source.to_a.map { |x| "#{x[0]} [#{x[1]*100}%]" }
        formatted_outdated_nodes = @outdated_nodes.to_a.map { |x| "#{x[0]} [#{x[1] / @@minutes_per_round} minutes]" }
        formatted_not_sshable = @not_sshable.to_a

        # [node observing outage, target] -> [node1 still connected, node2... ]
        srcdst2stillconnected = {}

        # [node observing outage, target] -> nodes with connectivity
        srcdst2formatted_connected = {}
        # [node observing outage, target] -> nodes without connectivity
        srcdst2formatted_unconnected = {}

        now = Time.new

        target2observingnode2rounds.each do |target, observingnode2rounds|
           if target2stillconnected[target].size >= @@vp_bound and
                  observingnode2rounds.delete_if { |node, rounds| rounds < @@lower_rounds_bound }.size >= @@vp_bound and
                  observingnode2rounds.delete_if { |node, rounds| rounds >= @@upper_rounds_bound }.size >= 1 and
                  !target2stillconnected[target].find { |node| (now - (@nodetarget2lastoutage[[node, target]] or Time.at(0))) / 60 > @@lower_rounds_bound }.nil? and
                  !observingnode2rounds.empty?

              # now convert still_connected to strings of the form
              # "#{node} [#{time of last outage}"]"
              formatted_connected = target2stillconnected[target].map { |node| "#{node} [#{@nodetarget2lastoutage[[node, target]] or "(n/a)"}]" }
              formatted_unconnected = observingnode2rounds.to_a.map { |x| "#{x[0]} [#{x[1] / @@minutes_per_round} minutes]"}
              formatted_never_seen = target2neverseen[target]

              dataset = FailureIsolation::get_dataset(target)

              log_outage_detected(target, dataset, formatted_unconnected,
                                              formatted_connected, formatted_never_seen, 
                                              formatted_problems_at_the_source,
                                              formatted_outdated_nodes, formatted_not_sshable)

              #Emailer.deliver_outage_detected(DNS::resolve_dns(target, target), dataset, formatted_unconnected,
              #                                formatted_connected, formatted_never_seen, 
              #                                formatted_problems_at_the_source,
              #                                formatted_outdated_nodes, formatted_not_sshable)

              # $LOG.puts "Tried to send an outage-detected email for #{target}"

              # don't issue isolation measurements for nodes which have
              # already issued measuremnt for this target in the last
              # @@isolation_interval rounds
              observingnode2rounds.delete_if { |node, rounds| @nodetarget2lastisolationattempt.include?([node,target]) and 
                  (@current_round - @nodetarget2lastisolationattempt[[node,target]] <= @@isolation_interval) }


              observingnode2rounds.keys.each do |src|
                 @nodetarget2lastisolationattempt[[src,target]] = @current_round
                 srcdst2stillconnected[[src,target]] = target2stillconnected[target]
                 # TODO: encapsulate these into objects rather than passing
                 # formatted/unformatted hash maps around
                 srcdst2formatted_connected[[src,target]] = formatted_connected
                 srcdst2formatted_unconnected[[src,target]] = formatted_unconnected
              end
           end
        end
        [srcdst2stillconnected, srcdst2formatted_connected, srcdst2formatted_unconnected]
    end

    def log_outage_detected(*args)
        t = Time.new
        File.open(FailureIsolation::OutageNotifications+"/#{args[0]}_#{t.year}#{t.month}#{t.day}#{t.hour}#{t.min}.yml", "w") { |f| YAML.dump(args, f) }
    end
end

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
        
        @db = DatabaseInterface.new

        @historical_trace_timestamp, @node2target2trace = YAML.load_file FailureIsolation::HistoricalTraces

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

        # quickly isolate the directions of the failures
        srcdst2pings_towards_src = issue_pings_towards_srcs(srcdst2stillconnected)
        $stderr.puts "srcdst2pings_towards_src: #{srcdst2pings_towards_src.inspect}"

        # if we control one of the targets, send out spoofed traceroutes in
        # the opposite direction for ground truth information
        symmetric_srcdst2stillconnected, srcdst2dstsrc = check4targetswecontrol(srcdst2stillconnected, registered_vps)
        
        # we check the forward direction by issuing spoofed traceroutes (rather than pings)
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
                                    srcdst2spoofed_tr[srcdst2dstsrc[srcdst]], testing)
                else
                    analyze_results(src, dst, srcdst2stillconnected[srcdst],
                                    srcdst2formatted_connected[srcdst], srcdst2formatted_unconnected[srcdst],
                                    srcdst2pings_towards_src[srcdst], srcdst2spoofed_tr[srcdst],
                                    testing)
                end
            end
        end
    end

    private

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

    def get_cached_revtr(src,dst)
        $stderr.puts "get_cached_revtr(#{src}, #{dst})"
        `#{FailureIsolation::CachedRevtrTool} #{src} #{dst}`.split("\n").map { |formatted| ReverseHop.new(formatted, @ipInfo) }
    end

    def analyze_results(src, dst, spoofers_w_connectivity, formatted_connected, formatted_unconnected, pings_towards_src, spoofed_tr, testing=false)
        $stderr.puts "analyze_results: #{src}, #{dst}"

        reverse_problem = pings_towards_src.empty?
        forward_problem = spoofed_tr.find { |hop| hop.ip == dst }.nil?

        direction = infer_direction(reverse_problem, forward_problem)

        # HistoricalForwardHop objects
        historical_tr_hops, historical_trace_timestamp = retrieve_historical_tr(src, dst)

        historical_tr_hops.each do |hop|
            # XXX thread out on this to make it faster? Ask Dave for a faster
            # way?
            hop.reverse_path = get_cached_revtr(src, hop.ip)
        end

        spoofed_revtr_hops = issue_spoofed_revtr(src, dst, historical_tr_hops.map { |hop| hop.ip })

        cached_revtr_hops = get_cached_revtr(src, dst)

        # We would like to know whether the hops on the historicalfoward/reverse/historicalreverse paths
        # are pingeable from the source. Send pings, and append the results to
        # the strings in the arrays (terrible, terrible, terrible)
        ping_responsive = issue_pings(src, dst, historical_tr_hops, 
                                      spoofed_revtr_hops[0].is_a?(Symbol) ? [] : spoofed_revtr_hops,
                                      cached_revtr_hops)

        fetch_historical_pingability!(historical_tr_hops,
                                      spoofed_revtr_hops[0].is_a?(Symbol) ? [] : spoofed_revtr_hops,
                                      cached_revtr_hops)

        # maybe not threadsafe, but fuckit
        tr = issue_normal_traceroute(src, [dst])

        # sometimes we oddly find that the destination is pingable from the
        # source after isolation measurements have completed
        destination_pingable = ping_responsive.include?(dst) || normal_tr_reached?(dst, tr)

        dataset = FailureIsolation::get_dataset(dst)

        # it's uninteresting if no measurements worked... probably the
        # source has no route
        forward_measurements_empty = (tr.size <= 1 && spoofed_tr.size <= 1)

        tr_reached_dst_AS = tr_reached_dst_AS?(dst, tr)

        log_name = get_uniq_filename(src, dst)

        jpg_output = "#{FailureIsolation::DotFiles}/#{log_name}.jpg"

        Dot::generate_jpg(src, dst, direction, dataset, tr, spoofed_tr, historical_tr_hops, spoofed_revtr_hops,
                             cached_revtr_hops, jpg_output)


        #                                    TODO: Turn this into a global constant 
        if(testing || (!destination_pingable && direction != "both paths seem to be working...?" &&
                !forward_measurements_empty && !tr_reached_dst_AS))

            graph_url = generate_web_symlink(jpg_output)

            Emailer.deliver_isolation_results(src, @ipInfo.format(dst), dataset, direction, formatted_connected, 
                                          formatted_unconnected, destination_pingable, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr_hops, historical_trace_timestamp,
                                          spoofed_revtr_hops, cached_revtr_hops, graph_url, testing)

            # Emailer.deliver_dot_graph(jpg_output)

            $stderr.puts "Attempted to send isolation_results email for #{src} #{dst} testing #{testing}..."
        end

        if(!testing)
            log_isolation_results(log_name, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, destination_pingable, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr_hops, historical_trace_timestamp,
                                          spoofed_revtr_hops, cached_revtr_hops)
        end
    end

    # XXX TERRIBLY REDUNDANT....
    def analyze_results_with_symmetry(src, dst, dsthostname, srcip, spoofers_w_connectivity,
                                      formatted_connected, formatted_unconnected, pings_towards_src,
                                      spoofed_tr, dst_spoofed_tr, testing=false)
        $stderr.puts "analyze_results: #{src}, #{dst}"

        reverse_problem = pings_towards_src.empty?
        forward_problem = spoofed_tr.find { |hop| hop.ip == dst }.nil?

        direction = infer_direction(reverse_problem, forward_problem)

        # HistoricalForwardHop objects
        historical_tr_hops, historical_trace_timestamp = retrieve_historical_tr(src, dst)

        historical_tr_hops.each do |hop|
            # XXX thread out on this to make it faster? Ask Dave for a faster
            # way?
            hop.reverse_path = get_cached_revtr(src, hop.ip)
        end

        spoofed_revtr_hops = issue_spoofed_revtr(src, dst, historical_tr_hops.map { |hop| hop.ip })

        cached_revtr_hops = get_cached_revtr(src, dst)

        # We would like to know whether the hops on the historicalfoward/reverse/historicalreverse paths
        # are pingeable from the source. Send pings, and append the results to
        # the strings in the arrays (terrible, terrible, terrible)
        ping_responsive = issue_pings(src, dst, historical_tr_hops, 
                                      spoofed_revtr_hops[0].is_a?(Symbol) ? [] : spoofed_revtr_hops,
                                      cached_revtr_hops)

        fetch_historical_pingability!(historical_tr_hops,
                                      spoofed_revtr_hops[0].is_a?(Symbol) ? [] : spoofed_revtr_hops,
                                      cached_revtr_hops)

        # maybe not threadsafe, but fuckit
        tr = issue_normal_traceroute(src, [dst])
        dst_tr = issue_normal_traceroute(dsthostname, [srcip]) 

        # sometimes we oddly find that the destination is pingable from the
        # source after isolation measurements have completed
        destination_pingable = ping_responsive.include?(dst) || normal_tr_reached?(dst, tr)

        dataset = FailureIsolation::get_dataset(dst)

        # it's uninteresting if no measurements worked... probably the
        # source has no route
        forward_measurements_empty = (tr.size <= 1 && spoofed_tr.size <= 1)

        tr_reached_dst_AS = tr_reached_dst_AS?(dst, tr)

        log_name = get_uniq_filename(src, dst)

        jpg_output = "#{FailureIsolation::DotFiles}/#{log_name}.jpg"

        Dot::generate_jpg(src, dst, direction, dataset, tr, spoofed_tr, historical_tr_hops, spoofed_revtr_hops,
                             cached_revtr_hops, jpg_output)


        #                                    TODO: Turn this into a global constant 
        if(testing || (!destination_pingable && direction != "both paths seem to be working...?" &&
                !forward_measurements_empty && !tr_reached_dst_AS))
             
            graph_url = generate_web_symlink(jpg_output)

            Emailer.deliver_symmetric_isolation_results(src, @ipInfo.format(dst), dataset, direction, formatted_connected, 
                                          formatted_unconnected, destination_pingable, pings_towards_src,
                                          tr, spoofed_tr,
                                          dst_tr, dst_spoofed_tr,
                                          historical_tr_hops, historical_trace_timestamp,
                                          spoofed_revtr_hops, cached_revtr_hops, graph_url, testing)

            # Emailer.deliver_dot_graph(jpg_output)

            $stderr.puts "Attempted to send isolation_results email for #{src} #{dst} testing #{testing}..."
        end

        if(!testing)
            log_symmetric_isolation_results(log_name, src, @ipInfo.format(dst), dataset, direction, formatted_connected, 
                                          formatted_unconnected, destination_pingable, pings_towards_src,
                                          tr, spoofed_tr,
                                          dst_tr, dst_spoofed_tr,
                                          historical_tr_hops, historical_trace_timestamp,
                                          spoofed_revtr_hops, cached_revtr_hops, testing)
        end
    end

    def generate_web_symlink(jpg_output)
        basename = File.basename(jpg_output)
        File.symlink(jpg_output, "/homes/network/revtr/www/isolation_graphs/#{basename}")
        "http://revtr.cs.washington.edu/isolation_graphs/#{basename}"
    end

    def infer_direction(reverse_problem, forward_problem)
        if(reverse_problem and !forward_problem)
            # failure is only on the reverse path
            direction = "reverse path"
            # spoof_traceroute_as_vps_to_use()
        #   for each (foward_hop n):
        #      issue_reverse_traceroute_from_n_to_s()
        # 
        #   m = first forward hop that does not yield a revtr to s
        #   do some comparison of m's historical reverse path to infer the router which is either failed or changed its path
        #   also ping everything on d's historical reverse path to see if those hops are still reachable
        #
        elsif(reverse_problem and forward_problem)
            # failure is bidirectional
            direction = "bi-directional"
        #   spoof_traceroute_as_vps_to_use()
        #   failure is adjacent to the last responsive forward hop seen by receivers (assuming only one failure)
        #
        elsif(!reverse_problem and forward_problem)
            # failure is only on the forward path
            direction = "forward path"
        #   spoof_revtr_from_d_to_s() # infer the working reverse path 
        #   issue_traceroutes_or_pings_to_reverse_hops() # get an idea of whether s can reach the reverse hops
        #
        #   spoof_traceroute_as_vps_to_use()
        #   failure is adjacent to the last responsive forward hop seen by s'
        #   we might also send pings to historical forward hops to see if the path has changed
        #
        else
            # just a lossy link?
            direction = "both paths seem to be working...?"
        end

        direction
    end

    def tr_reached_dst_AS?(dst, tr)
        dest_as = @ipInfo.getASN(dst)
        last_non_zero_hop = find_last_non_zero_hop_of_tr(tr)
        last_hop_as = (last_non_zero_hop.nil?) ? nil : @ipInfo.getASN(last_non_zero_hop)
        return !dest_as.nil? && !last_hop_as.nil? && dest_as == last_hop_as
    end

    def find_last_non_zero_hop_of_tr(tr)
        last_hop = tr.reverse.find { |hop| hop.ip != "0.0.0.0" }
        return (last_hop.nil?) ? nil : last_hop.ip
    end

    def normal_tr_reached?(dst, tr)
        normal_tr_reached = (!tr.empty? && tr[-1].ip == dst)
        $stderr.puts "normal_tr_reached?: #{normal_tr_reached}"
        normal_tr_reached
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
        $LOG.puts "isolate_spoofed_traceroutes, srcdst2stillconnected: #{srcdst2stillconnected.inspect}"
        srcdst2sortedttlrtrs = @registrar.batch_spoofed_traceroute(srcdst2stillconnected)

        srcdst2spoofed_tr = {}

        $LOG.puts "isolate_spoofed_traceroutes, srcdst2ttl2rtrs: #{srcdst2sortedttlrtrs.inspect}"

        srcdst2stillconnected.keys.each do |srcdst|
            src, dst = srcdst
            if srcdst2sortedttlrtrs.nil? || srcdst2sortedttlrtrs[srcdst].nil?
                srcdst2spoofed_tr[srcdst] = []
            else
                srcdst2spoofed_tr[srcdst] = srcdst2sortedttlrtrs[srcdst].map { |ttlrtrs| SpoofedForwardHop.new(ttlrtrs, @ipInfo) }
            end
        end

        srcdst2spoofed_tr
    end

    # precondition: targets is a single element array
    def issue_normal_traceroute(src, targets)
        dest2ttlhoptuples = @registrar.traceroute(src, targets, true)
        dst = targets[0] # ugghh..

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
    def issue_pings(source, dest, historical_tr_hops, spoofed_revtr_hops, cached_revtr_hops)
        all_hop_sets = [historical_tr_hops, spoofed_revtr_hops, cached_revtr_hops]
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

    def fetch_historical_pingability!(historical_tr_hops, spoofed_revtr_hops, cached_revtr_hops)
        # TODO: redundannnnttt
        all_hop_sets = [historical_tr_hops, spoofed_revtr_hops, cached_revtr_hops]
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
        "#{src}#{dst}_#{t.year}#{t.month}#{t.day}#{t.hour}#{t.min}"
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

if __FILE__ == $0
    begin
       dispatcher = FailureDispatcher.new
       monitor = FailureMonitor.new(dispatcher)

       Signal.trap("TERM") { monitor.persist_state; exit }
       Signal.trap("KILL") { monitor.persist_state; exit }

       monitor.start_pull_cycle((ARGV.empty?) ? $default_period_seconds : ARGV.shift.to_i)
    rescue Exception => e
       Emailer.deliver_isolation_exception("#{e} \n#{e.backtrace.join("<br />")}") 
       monitor.persist_state
       throw e
    end
end
