require 'failure_dispatcher'
require 'vp_house_cleaning'
require 'isolation_module'
require 'isolation_probe_status'
require 'set'
require 'yaml'
require 'outage'

# responsible for pulling state from ping monitors, classifying outages, and
# dispatching interesting outages to FailureDispatcher
class FailureMonitor
    def initialize(dispatcher, db=DatabaseInterface.new, email="failures@cs.washington.edu")
        @dispatcher = dispatcher
        @db = db
        @email = email

        # TODO: handle these with optparse
        @@minutes_per_round = 2
        @@timestamp_bound = 605
        @@upper_rounds_bound = 500
        @@lower_rounds_bound = 4
        @@vp_bound = 1

        # if a VP misses more than 10 measurements,swap it out
        @@failed_measurement_threshold = 10  

        # if more than 70% of a node's targets are unreachable, we ignore the
        # node
        @@source_specific_problem_threshold = 0.35
        # how often we send out faulty_node_audit reports
        @@node_audit_period = 60*60*24 / FailureIsolation::DefaultPeriodSeconds / 3

        @@outdated_node_threshold = 20

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
        @not_sshable = Set.new

        # so that we don't probe the hell out of failed routers
        # target -> time
        @nodetarget2lastisolationattempt = {}
        # minimum time in between successive isolation measurements sent from
        # a source to a destination
        @@isolation_interval = 30 # we isolate at most every 6*10.33 =~ 60 minutes

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
            start = Time.new

            @target_blacklist = Set.new(IO.read(FailureIsolation::TargetBlacklist).split("\n"))

            # TODO: cat directly from ssh rather than scp'ing
            system "#{$pptasks} scp #{FailureIsolation::MonitorSlice} #{FailureIsolation::MonitoringNodes} 100 100 \
                     @:#{FailureIsolation::PingMonitorState} :#{FailureIsolation::PingMonitorRepo}state"

            node2targetstate = read_in_results()

            update_auxiliary_state(node2targetstate)

            target2observingnode2rounds, target2neverseen, target2stillconnected = classify_outages(node2targetstate)
            
            srcdst2outage = send_notification(target2observingnode2rounds, target2neverseen, target2stillconnected)

            @dispatcher.isolate_outages(srcdst2outage)

            $LOG.puts "round #{@current_round} completed"
            $stderr.flush
            @current_round += 1
            
            swap_out_faulty_nodes if (@current_round % @@node_audit_period) == 0

            sleep_period =  period - (Time.new - start)

            sleep sleep_period if sleep_period > 0
        end
    end

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

        # nodes with problems at the source are excluded from node2targetstate
        node2targetstate
    end

    def swap_out_faulty_nodes()
        # First check if no nodes are left to swap out
        if File.size(FailureIsolation::AllNodesPath) == File.size(FailureIsolation::BlackListPath)
            Emailer.deliver_isolation_exception("No nodes left to swap out!\nSee: ~revtr/spoofed_traceroute/blacklisted_isolation_nodes.txt")
            return
        end

        already_blacklisted = Set.new(IO.read(FailureIsolation::BlackListPath).split("\n"))

        to_swap_out = Set.new

        outdated = @outdated_nodes
        @outdated_nodes = {}
        to_swap_out |= outdated.map { |k,v| k }
        
        source_problems = @problems_at_the_source
        @problems_at_the_source = {}
        to_swap_out |= source_problems.keys

        not_sshable = @not_sshable
        @not_sshable = Set.new
        to_swap_out |= not_sshable

        # XXX clear node_2_failed_measurements state
        failed_measurements = @dispatcher.node_2_failed_measurements.find_all { |node,missed_count| missed_count > @@failed_measurement_threshold }
        to_swap_out |= failed_measurements.map { |k,v| k }

        bad_srcs, possibly_bad_srcs = HouseCleaning::check_source_probing_status(@db)
        to_swap_out += bad_srcs

        to_swap_out -= already_blacklisted

        return if to_swap_out.empty?

        Emailer.deliver_faulty_node_report(outdated,
                                           source_problems,
                                           not_sshable,
                                           failed_measurements,
                                           bad_srcs,
                                           possibly_bad_srcs)

        HouseCleaning::swap_out_faulty_nodes(to_swap_out)
    end

    def update_auxiliary_state(node2targetstate)
        current_time = Time.now

        node2targetstate.each do |node, target_state|
            target_state.keys.each do |target|
                @nodetarget2lastoutage[[node,target]] = current_time
            end

            # We updated nodes while isolation_module.rb was running...
            if @vps_2_targets_never_seen[node].nil?
                @vps_2_targets_never_seen[node] = @all_targets
            end

            if !@vps_2_targets_never_seen[node].empty?
                @vps_2_targets_never_seen[node] -= (@all_targets - Set.new(target_state.keys)) 
            end
        end
    end

    def remove_node(node)
        @nodetarget2lastoutage.delete_if { |n,t| n[0] == node }
        @vps_2_targets_never_seen.delete node
        @problems_at_the_source.delete node
        @outdated_nodes.delete node
        @all_nodes.delete node
        @not_sshable.delete node
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
        # [node observing outage, target] -> outage struct
        srcdst2outage = {}

        now = Time.new

        target2observingnode2rounds.each do |target, observingnode2rounds|
           # Boy... this is a mess.
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

              # don't issue isolation measurements for nodes which have
              # already issued measuremnt for this target in the last
              # @@isolation_interval rounds
              observingnode2rounds.delete_if { |node, rounds| @nodetarget2lastisolationattempt.include?([node,target]) and 
                  (@current_round - @nodetarget2lastisolationattempt[[node,target]] <= @@isolation_interval) }

              observingnode2rounds.keys.each do |src|
                 @nodetarget2lastisolationattempt[[src,target]] = @current_round
                 # XXX Multiplex on Symmetry here?
                 srcdst2outage[[src,target]] = Outage.new(src, target, formatted_connected, formatted_unconnected, formatted_never_seen)
              end
           end
        end

        srcdst2outage
    end

    def log_outage_detected(*args)
        t = Time.new
        File.open(FailureIsolation::OutageNotifications+"/#{args[0]}_#{t.year}#{t.month}#{t.day}#{t.hour}#{t.min}.yml", "w") { |f| YAML.dump(args, f) }
    end
end

