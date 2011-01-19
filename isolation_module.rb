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
require '../spooftr_config.rb' # XXX don't hardcode...

# XXX Don't hardcode!!!
$pptasks = "~ethan/scripts/pptasks"
$default_period = 350
Thread.abort_on_exception = true

module FailureIsolation
    # out of place...
    FailureIsolation::ControllerUri = IO.read("#{$DATADIR}/uris/controller.txt").chomp
    FailureIsolation::RegistrarUri = IO.read("#{$DATADIR}/uris/registrar.txt").chomp

    # XXX terrible terrible
    FailureIsolation::CloudfrontTargets = [ "204.246.165.221", "204.246.169.63", "216.137.33.1",
        "216.137.35.21", "216.137.37.156", "216.137.39.152", "216.137.41.78",
        "216.137.43.189", "216.137.45.33", "216.137.47.127", "216.137.53.96",
        "216.137.55.170", "216.137.57.207", "216.137.59.4", "216.137.61.174",
        "216.137.63.221" ]

    FailureIsolation::TargetSet = "/homes/network/revtr/spoofed_traceroute/current_target_set.txt"

    FailureIsolation::PingMonitorState = "~/colin/target_state.yml"
    FailureIsolation::PingMonitorRepo = "#{$DATADIR}/ping_monitoring_state/"

    FailureIsolation::MonitoringNodes = "/homes/network/revtr/spoofed_traceroute/cloudfront_spoofing_monitoring_nodes.txt"

    FailureIsolation::MonitorSlice = "uw_revtr2"
    FailureIsolation::IsolationSlice = "uw_revtr" # why do we separate the slices?

    FailureIsolation::RevtrRequests = "/homes/network/revtr/failure_isolation/revtr_requests/current_requests.txt"

    FailureIsolation::HistoricalTraces = "#{$DATADIR}/most_recent_historical_traces.txt"

    FailureIsolation::CachedRevtrTool = "~/dave/revtr-test/reverse_traceroute/print_cached_reverse_path.rb"

    FailureIsolation::DataSetDir = "/homes/network/revtr/spoofed_traceroute/datasets"
    # targets taken from Harsha's most well connected PoPs
    FailureIsolation::HarshaPoPs = "#{FailureIsolation::DataSetDir}/responsive_corerouters.txt"
    # targets taken from routers on paths beyond Harsha's most well connected PoPs
    FailureIsolation::BeyondHarshaPoPs = "#{FailureIsolation::DataSetDir}/responsive_edgerouters.txt"
    # targets taken from spoofers.hosts
    FailureIsolation::SpooferTargets = "#{FailureIsolation::DataSetDir}/one_spoofer_per_site_ips.txt"
end

class FailureMonitor
    def initialize(dispatcher, email="failures@cs.washington.edu")
        @dispatcher = dispatcher
        @email = email

        # TODO: handle these with optparse
        @@timestamp_bound = 605
        @@rounds_bound = 8
        @@vp_bound = 2
        # if more than 70% of a node's targets are unreachable, we ignore the
        # node
        @@source_specific_problem_threshold = 0.50

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
        rescue
            @vps_2_targets_never_seen = {}

            # unresponsive until proven otherwise
            File.foreach(FailureIsolation::MonitoringNodes) { |node| @vps_2_targets_never_seen[node.chomp] = @all_targets }
        end
        
        @@last_outage_yml = "./last_outages.yml"
        begin
            # [node, target] -> last time outage was observed
            @nodetarget2lastoutage = (File.readable? @@last_outage_yml) ? YAML.load_file(@@last_outage_yml) : {}
        rescue
            @nodetarget2lastoutage = {}
        end

        @outdated_nodes = {}
        @problems_at_the_source = {}

        # so that we don't probe the hell out of failed routers
        # target -> time
        @target2lastisolationattempt = {}
        @@isolation_interval = 6 # we isolate at most every 6*5 = 30 minutes

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
            system "#{$pptasks} scp #{FailureIsolation::MonitorSlice} #{FailureIsolation::MonitoringNodes} 100 100 \
                     @:#{FailureIsolation::PingMonitorState} :#{FailureIsolation::PingMonitorRepo}state"

            node2targetstate = read_in_results()

            update_auxiliary_state(node2targetstate)

            target2observingnode2rounds, target2neverseen, target2stillconnected = classify_outages(node2targetstate)
            
            send_notification(target2observingnode2rounds, target2neverseen, target2stillconnected)

            $LOG.puts "round #{@current_round} completed"
            @current_round += 1

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
                @problems_at_the_source[node] = failure_percentage
                $LOG.puts "Problem at the source: #{node}"
                next
            end

            @outdated_nodes.delete node
            @problems_at_the_source.delete node
            node2targetstate[node] = hash
        end

        node2targetstate
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
        formatted_outdated_nodes = @outdated_nodes.to_a.map { |x| "#{x[0]} [#{x[1]} minutes]" }
        formatted_not_sshable = @not_sshable.to_a

        target2observingnode2rounds.each do |target, observingnode2rounds|
           if observingnode2rounds.size >= @@vp_bound and target2stillconnected[target].size >= @@vp_bound and
                  observingnode2rounds.values.select { |rounds| rounds >= @@rounds_bound }.size >= @@vp_bound
              # now convert still_connected to strings of the form
              # "#{node} [#{time of last outage}"]"
              formatted_connected = target2stillconnected[target].map { |node| "#{node} [#{@nodetarget2lastoutage[[node, target]] or "(n/a)"}]" }
              formatted_unconnected = observingnode2rounds.to_a.map { |x| "#{x[0]} [#{x[1]} minutes]"}
              formatted_never_seen = target2neverseen[target]

              # probably a better way to do this..., but...
              Emailer.deliver_outage_detected(target, formatted_unconnected, formatted_connected,
                                              formatted_never_seen, formatted_problems_at_the_source,
                                              formatted_outdated_nodes, formatted_not_sshable)

              $LOG.puts "Tried to send an outage-detected email for #{target}"
               
              if !@target2lastisolationattempt.include?(target) or (@current_round - @target2lastisolationattempt[target] > @@isolation_interval)
                 @target2lastisolationattempt[target] = @current_round

                 observingnode2rounds.keys.each do |node|
                     Thread.new { @dispatcher.isolate_outage(node, target, target2stillconnected[target]) }
                 end
              end
           end
        end
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
        @rtrSvc = connect_to_drb

        @harsha_targets = Set.new(IO.read(FailureIsolation::HarshaPoPs).split("\n"))
        @beyond_harsha_targets = Set.new(IO.read(FailureIsolation::BeyondHarshaPoPs).split("\n"))
        @spoofer_targets = Set.new(IO.read(FailureIsolation::SpooferTargets).split("\n"))
        @cloudfront_targets = Set.new(FailureIsolation::CloudfrontTargets)

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
            uri_location = "http://revtr.cs.washington.edu/vps/failure_isolation/spoof_only_rtr_module.txt"
            uri = Net::HTTP.get_response(URI.parse(uri_location)).body
            rtrSvc = DRbObject.new nil, uri
        end
    end

    # receive spoofed reverse traceroute results asynchronously from Dave
    def send_results(src, dst, results)
        $LOG.puts "send_results: #{source.inspect} #{dst.inspect} #{results.inspect}"
    end

    # precondition: spoofers_w_connectivity are able to reach dst
    def isolate_outage(src, dst, spoofers_w_connectivity, testing=false)
        registered_vps = @controller.hosts.clone
        return unless registered_vps.include?(src) && !(registered_vps & spoofers_w_connectivity).empty?

        # TODO: one thread for each direction
        targets = [dst]

        # quickly isolate the direction(s) of failure
        pings_towards_src = issue_pings_towards_src(src, targets, spoofers_w_connectivity)
        reverse_problem = pings_towards_src.empty?

        # we check the forward direction by issuing a spoofed traceroute (rather than pings)
        spoofed_tr_ttlhopstuples = issue_spoofed_traceroute(src, targets, spoofers_w_connectivity)
        $stderr.puts "spoofed_tr_ttlhopstuples: #{spoofed_tr_ttlhopstuples.inspect}"
        forward_problem = spoofed_tr_ttlhopstuples.find { |ttlhops| ttlhops[1].include? dst }.nil?

        historical_tr_ttlhoptuples, historical_trace_timestamp = retrieve_historical_tr(src, dst)

        revtr_array = issue_spoofed_revtr(src, dst)

        cached_revtr_array = `#{FailureIsolation::CachedRevtrTool} #{src} #{dst}`.split("\n")

        # We would like to know whether the hops on the historicalfoward/reverse/historicalreverse paths
        # are pingeable from the source. Send pings, and append the results to
        # the strings in the arrays (terrible, terrible, terrible)
        ping_responsive = issue_pings(src, dst, historical_tr_ttlhoptuples, revtr_array, cached_revtr_array)
        # sometims we oddly find that the destination is pingable from the
        # source after isolation measurements have completed
        destination_pingable = ping_responsive.include? dst

        tr_ttlhoptuples = issue_normal_traceroute(src, targets)

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

        dataset = get_dataset(dst)

        Emailer.deliver_isolation_results(src, resolve_dns(dst, dst), dataset, direction, spoofers_w_connectivity, 
                                          destination_pingable, pings_towards_src,
                                          format_ttlhops(tr_ttlhoptuples), 
                                          format_ttlhops(spoofed_tr_ttlhopstuples),
                                          format_ttlhops_w_reachability(historical_tr_ttlhoptuples, ping_responsive),
                                          historical_trace_timestamp,
                                          revtr_array, cached_revtr_array, testing)

        $stderr.puts "Attempted to send isolation_results email for #{src} #{dst}..."
    end

    # output format:
    #
    # synopsis:
    #    Source:
    #    Destination:
    #    Spoofers with connectivity:
    #    Failed Router:
    #    Direction: #{forward/reverse/bidirectional}
    # ==========================================
    # succesful receivers for #{target}:     
    #   -
    #   -
    #   -
    # ==========================================
    # succesful spoofers for #{target}:
    #   -
    #   -
    #   -
    # ==========================================
    # spoofed forward traceroute:
    #   -     (reverse traceroute for each hop?)
    #   -
    #   -
    # ==========================================
    # historical forward traceroute:
    #   -     (can still reach?)
    #   -
    #   -
    # ==========================================
    # spoofed reverse traceroute:
    #   -     (can S ping each hop?)
    #   -
    #   -
    # ==========================================
    # historical reverse traceroute:
    #   -     (still reachable for each hop?)
    #   -
    #   -
    private

    def get_dataset(dst)
        if @harsha_targets.include? dst
            return "Harsha's most well-connected PoPs"
        elsif @beyond_harsha_targets.include? dst
            return "Routers on paths beyond Harsha's PoPs"
        elsif @cloudfront_targets.include? dst
            return "CloudFront"
        elsif @spoofer_targets.include? dst
            return "PL/mlab nodes"
        else
            return "Unkown"
        end
    end

    def format_ttlhops(ttlhops)
        ttlhops.map do |ttlhops| 
            ttl, hops = ttlhops
            hops = [hops] unless hops.is_a?(Array) or hops.is_a?(Set)
            resolved_hops = hops.map { |hop| resolve_dns(hop, hop) }.join ', '
            "#{ttl}.  #{resolved_hops}"
        end
    end

    # XXX redundannnnnnttttt
    def format_ttlhops_w_reachability(ttlhops, reachable)
        ttlhops.map do |ttlhops|
            ttl, hops = ttlhops
            hops = [hops] unless hops.is_a?(Array)
            resolved_hops = hops.map { |hop| "#{resolve_dns(hop, hop)} (pingable from S?: #{reachable.include? hop})" }.join ', '
            "#{ttl}.  #{resolved_hops}"
        end
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

        [historical_tr_ttlhoptuples, historical_trace_timestamp]
    end

    # precondition: targets is a single element array
    def issue_pings_towards_src(src, targets, spoofers_w_connectivity)
        dst = targets[0] # hmmmm

        # hash is target2receiver2succesfulvps
        spoofed_ping_results = @registrar.receive_spoofed_pings(src, targets, spoofers_w_connectivity, true)
        $LOG.puts "isolate_outage(#{src}, #{dst}), spoofed_ping_results: #{spoofed_ping_results.inspect}"

        if spoofed_ping_results.nil? || spoofed_ping_results[dst].nil? || spoofed_ping_results[dst][src].nil?
            pings_towards_src = [] 
        else
            pings_towards_src = spoofed_ping_results[dst][src]
        end

        pings_towards_src
    end

    # precondition: targets is a single element array
    def issue_spoofed_traceroute(src, targets, spoofers_w_connectivity)
        traceroute_results = @registrar.client_spoofed_traceroute(src, targets, spoofers_w_connectivity, true)
        dst = targets[0] # ugghh...

        $LOG.puts "isolate_outage(#{src}, #{dst}), spoofed_traceroute_results: #{traceroute_results.inspect}"

        if traceroute_results.nil? || traceroute_results[dst].nil?
            spoofed_tr_ttlhopstuples = {}
        else
            spoofed_tr_ttlhopstuples = traceroute_results[dst].to_a.sort_by { |tuple| tuple[0] }
        end

        spoofed_tr_ttlhopstuples
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

        tr_ttlhoptuples
    end

    # XXX change me later to deal with revtrs from forward hops
    def issue_spoofed_revtr(src, dst)
        begin
            srcdst2revtr = @rtrSvc.get_reverse_paths([[src, dst]])
        rescue Exception => e
            Emailer.deliver_isolation_exception("#{e} \n#{e.backtrace.join("<br />")}") 
            @drb = connect_to_drb()  # this is going to happen multiple times if more than one thread calls throws an exception...
            return [:drb_exception]
        end

        $LOG.puts "isolate_outage(#{src}, #{dst}), srcdst2revtr: #{srcdst2revtr.inspect}"

        if srcdst2revtr.nil? || srcdst2revtr[[src,dst]].nil?
            return [:nil_return_value]
        end
                
        revtr = srcdst2revtr[[src,dst]]
        
        if revtr.is_a?(Symbol) 
            # The request failed -- the symbol tells us the cause of the failure
            spoofed_revtr = [revtr]
        else
            # XXX string -> array -> string. meh.
            spoofed_revtr = revtr.get_revtr_string.split("\n")
        end

        $LOG.puts "isolate_outage(#{src}, #{dst}), spoofed_revtr: #{spoofed_revtr.inspect}"
        
        spoofed_revtr
    end

    # take the string form, and turn it into sorted ttlhoptuples
    # ideally we wouldn't be doing string processing like this...
    # TODO: add this functionality to the ReverseTraceroute class
    def extract_hops_from_revtr_string_array(revtr)
        hop2string = {} 
        revtr.each do |line|
            next unless line.is_a?(String) # if it's a symbol, the revtr failed
            
            # 1 netrom.demarc.cogentco.com (38.101.50.62) dst
            match = line.scan(/\d+.*\((.*)\).*/)
            next if match.empty?
            hop2string[match[0][0]] = line
        end

        hop2string
    end

    # We would like to know whether the hops on the historicalfoward/reverse/historicalreverse paths
    # are pingeable from the source. Send pings, and append the results to
    # the strings in the revtr arrays (terrible, terrible, terrible). For now,
    # we don't append strings to the forward traceroute arrays
    def issue_pings(source, dest, historical_tr_ttlhoptuples, revtr_array, cached_revtr_array)
        # hop -> string in the historical_tr_ttlhoptuples array
        historical_tr_hops = historical_tr_ttlhoptuples.map { |ttlhop| ttlhop[1] }

        # hop -> string in the revtr_array
        rtr_to_string = extract_hops_from_revtr_string_array(revtr_array)

        # hop -> string in the cached_revtr_array
        historical_rtr_to_string = extract_hops_from_revtr_string_array(cached_revtr_array)

        all_targets = Set.new(historical_tr_hops + rtr_to_string.keys + historical_rtr_to_string.keys)
        all_targets.add dest

        responsive = @registrar.ping(source, all_targets.to_a, true)

        all_targets.each do |hop|
            pingable = responsive.include? hop

            if rtr_to_string.include? hop
                right_justify(rtr_to_string[hop], pingable)
            end

            if historical_rtr_to_string.include? hop
               right_justify(historical_rtr_to_string[hop], pingable)
            end
        end

        responsive
    end

    def right_justify(str_pointer, pingable)
        # this is a terrible terrible hack. We want to justify all of the
        # columns in the email. We can't use rjust, since there is no
        # rjust! version that mutates the string. << mutates the string,
        # so we << in the right number of spaces, then we put in the
        # "(pingable?: )" part.
        str_pointer << "&nbsp;&nbsp;&nbsp;(pingable from S?: #{pingable})"
    end

    def get_addr(dst)
        begin
            dst_ip=Resolv.getaddress(dst)
        rescue
            $stderr.puts "Unable to resolve #{dst}: #{$!}"
        end
    end

    def resolve_dns(dst, dst_ip)
        ((dst_ip==dst) ? "#{Resolv.getname(dst) rescue dst} (#{dst})" : "#{dst} (#{dst_ip})")
    end
end

if __FILE__ == $0
    exit # XXX
    begin
       dispatcher = FailureDispatcher.new
       monitor = FailureMonitor.new(dispatcher)

       Signal.trap("TERM") { monitor.persist_state; exit }
       Signal.trap("KILL") { monitor.persist_state; exit }

       monitor.start_pull_cycle((ARGV.empty?) ? $default_period : ARGV.shift.to_i)
    rescue Exception => e
       Emailer.deliver_isolation_exception("#{e} \n#{e.backtrace.join("<br />")}") 
       monitor.persist_state
       throw e
    end
end
