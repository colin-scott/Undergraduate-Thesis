#!/homes/network/revtr/ruby/bin/ruby
require 'failure_dispatcher'
require 'house_cleaner'
require 'failure_isolation_consts'
require 'set'
require 'yaml'
require 'outage'
require 'filter_stats'
require 'utilities'
require 'filters'

# responsible for pulling state from ping monitors, classifying outages, and
# dispatching interesting outages to FailureDispatcher
class FailureMonitor
    include FirstLevelFilters

    def initialize(dispatcher=FailureDispatcher.new, db=DatabaseInterface.new, logger=LoggerLog.new($stderr), email="failures@cs.washington.edu")
        @dispatcher = dispatcher
        @db = db
        @logger = logger
        @email = email
        @house_cleaner = HouseCleaner.new(logger, @db)

        # TODO: handle these with optparse
        @@minutes_per_round = 2
        @@timestamp_bound = 605

        # if a VP misses more than 10 measurements,swap it out
        @@failed_measurement_threshold = 10  

        # if more than 70% of a node's targets are unreachable, we ignore the
        # node
        @@source_specific_problem_threshold = 0.35
        # how often we send out faulty_node_audit reports
        @@node_audit_period = 24*60 / @@minutes_per_round

        @@outdated_node_threshold = 20

        @target_set_size = FailureIsolation.TargetSet.size

        @all_targets = FailureIsolation.TargetSet

        @all_nodes = FailureIsolation.CurrentNodes

        @@never_seen_yml = "./targets_never_seen.yml"
        begin
            @vps_2_targets_never_seen = YAML.load_file(@@never_seen_yml)
            raise unless @vps_2_targets_never_seen
        rescue
            @vps_2_targets_never_seen = {}

            # unresponsive until proven otherwise
            @all_nodes.each { |node| @vps_2_targets_never_seen[node.chomp] = @all_targets }
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
        @node_target2lastisolationattempt = {}

        # minimum time in between successive isolation measurements sent from
        # a source to a destination
        @@isolation_interval = 90

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

            # TODO: cat directly from ssh rather than scp'ing
            system "#{FailureIsolation::PPTASKS} scp #{FailureIsolation::MonitorSlice} #{FailureIsolation::CurrentNodesPath} 100 100 \
                     @:#{FailureIsolation::PingMonitorState} :#{FailureIsolation::PingMonitorRepo}state"

            # ==================================== #                                                                                                                                 
            #    riot specific!                    #                                                                                                                                 
            # ==================================== #                                                                                                                                 
            system "scp cs@riot.cs.washington.edu:~/ping_monitors/state.* #{FailureIsolation::PingMonitorRepo}"

            node2targetstate = read_in_results()

            update_auxiliary_state(node2targetstate)

            target2observingnode2rounds, target2neverseen, target2stillconnected = classify_outages(node2targetstate)
            
            srcdst2outage, dst2filter_tracker = send_notification(target2observingnode2rounds, target2neverseen, target2stillconnected)

            @dispatcher.isolate_outages(srcdst2outage, dst2filter_tracker)

            @logger.puts "round #{@current_round} completed"
            @current_round += 1
            
            clean_the_house if (@current_round % @@node_audit_period) == 0

            sleep_period = period - (Time.new - start)
            @logger.info "Sleeping for #{sleep_period} seconds"

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

            node = yaml.split("state.")[1].strip.downcase

            seconds_difference = (current_time - mtime).abs
            if seconds_difference >= @@timestamp_bound
                minutes_difference = seconds_difference / 60
                @outdated_nodes[node] = minutes_difference
                @logger.puts "#{node}'s data is #{minutes_difference} minutes out of date"
                next
            end

            @not_sshable.delete node

            # "state.node1.pl.edu"
            begin
                yml_hash = YAML.load_file(yaml)

                if !yml_hash.is_a?(Hash)
                    @logger.puts "#{node}'s data was not a hash!!"
                    next
                end

                # we want to strip targets
                hash = {}
                yml_hash.each do |k,v|
                   hash[k.strip] = v
                end 
            rescue
                @logger.puts "Corrupt YAML file: #{node}"
                next
            end

            failure_percentage = hash.size * 1.0 / @target_set_size
            if (!FailureIsolation::PoisonerNames.include? node and failure_percentage > @@source_specific_problem_threshold) or
                    (FailureIsolation::PoisonerNames.include? node and failure_percentage == 1.0)
                @problems_at_the_source[node] = failure_percentage * 100
                @logger.puts "Problem at the source: #{node}"
                next
            end

            @outdated_nodes.delete node
            @problems_at_the_source.delete node
            node2targetstate[node] = hash
        end

        # nodes with problems at the source are excluded from node2targetstate
        node2targetstate
    end

    def clean_the_house()
        Thread.new do
            swap_out_faulty_nodes
            swap_out_unresponsive_targets
        end
    end

    def swap_out_faulty_nodes()
        # First check if no nodes are left to swap out
        if (FailureIsolation.AllNodes - FailureIsolation.NodeBlacklist).empty?
            Emailer.deliver_isolation_exception("No nodes left to swap out!\nSee: #{FailureIsolation::NodeBlacklistPath}")
            return
        end
        
        to_swap_out,outdated,source_problems,not_sshable,failed_measurements,
            not_controllable,bad_srcs,possibly_bad_srcs,outdated = identify_faulty_nodes

        @logger.debug "finished finding substitites for vps"

        Emailer.deliver_faulty_node_report(outdated,
                                           source_problems,
                                           not_sshable,
                                           not_controllable,
                                           failed_measurements,
                                           bad_srcs,
                                           possibly_bad_srcs)

        return if to_swap_out.empty?

        @house_cleaner.swap_out_faulty_nodes(to_swap_out)
    end

    def swap_out_unresponsive_targets
        dataset2substitute_targets, dataset2unresponsive_targets, possibly_bad_targets, bad_hops, possibly_bad_hops = \
                @house_cleaner.find_substitutes_for_unresponsive_targets()
        @logger.debug "finished finding substitutes for targets"

        Emailer.deliver_isolation_status(dataset2unresponsive_targets, possibly_bad_targets, bad_hops, possibly_bad_hops)
         
        @house_cleaner.swap_out_unresponsive_targets(dataset2unresponsive_targets, dataset2substitute_targets) 
    end
     
    def identify_faulty_nodes()
        already_blacklisted = FailureIsolation.NodeBlacklist

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
        
        not_controllable_hostname2ip = @db.uncontrollable_isolation_vantage_points()
        not_controllable = not_controllable_hostname2ip.keys

        # remove from target list
        # substitutes implemented separately
        @house_cleaner.swap_out_unresponsive_targets(not_controllable_hostname2ip.values, {})
        to_swap_out |= not_controllable

        # XXX clear node_2_failed_measurements state
        failed_measurements = @dispatcher.node_2_failed_measurements.find_all { |node,missed_count| missed_count > @@failed_measurement_threshold }
        to_swap_out |= failed_measurements.map { |k,v| k }

        bad_srcs, possibly_bad_srcs = @db.check_source_probing_status()
        to_swap_out += bad_srcs

        to_swap_out -= already_blacklisted

        return [to_swap_out,outdated,source_problems,not_sshable,
            failed_measurements,not_controllable,bad_srcs,possibly_bad_srcs,outdated]
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

    def classify_outages(node2targetstate, testing=false)
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
               next if FailureIsolation.TargetBlacklist.include? target
               # XXX For backwards compatibility...
               rounds = rounds[0] if rounds.is_a?(Array)

               if rounds.nil?
                   @logger.puts "#{node}: #{target} is nil..."
                   next
               end
                
               all_targets.add target

               if @vps_2_targets_never_seen.include? node
                    if !@vps_2_targets_never_seen[node].include? target
                        target2observingnode2rounds[target][node] = rounds
                    else 
                        target2neverseen[target] << node
                    end
               else 
                   @logger.warn "node #{node} not known by monitor.."
                   target2observingnode2rounds[target][node] = rounds
               end
            end
        end

        all_targets.each do |target|
            target2stillconnected[target] = active_nodes - (target2neverseen[target] + target2observingnode2rounds[target].keys)
        end

        [target2observingnode2rounds, target2neverseen, target2stillconnected]
    end

    def passes_first_level_filters?(target, observingnode2rounds, stillconnected)
        filter_tracker = FirstLevelFilters.filter(target, observingnode2rounds, stillconnected, @nodetarget2lastoutage)

        # TODO: move this into FirstLevelFilters?
        # don't issue isolation measurements for targets which have
        # already been probed recently
        observingnode2rounds.each do |node, rounds|
            if @node_target2lastisolationattempt.include? [node,target] and 
                        (@current_round - @node_target2lastisolationattempt[[node,target]] <= @@isolation_interval)
                observingnode2rounds.delete node 
            else
                @node_target2lastisolationattempt[[node,target]] = @current_round
            end
        end

        if observingnode2rounds.empty?
            filter_tracker.failure_reasons << ALL_NODES_ISSUED_MEASUREMENTS_RECENTLY 
        end

        return filter_tracker
    end

    def send_notification(target2observingnode2rounds, target2neverseen, target2stillconnected)
        # [node observing outage, target] -> outage struct
        srcdst2outage = {}
        dst2filter_tracker =  {}
        filter_stats = []

        target2observingnode2rounds.each do |target, observingnode2rounds|
            filter_tracker = passes_first_level_filters?(target, observingnode2rounds, target2stillconnected[target])
            filter_stats << filter_tracker
            next unless filter_tracker.passed?

            # TODO: encpasulate VPs into objects, so the to_s automatically
            # yields the formatted string
            #
            # now convert still_connected to strings of the form
            # "#{node} [#{time of last outage}"]"
            formatted_connected = target2stillconnected[target].map { |node| "#{node} [#{@nodetarget2lastoutage[[node, target]] or "(n/a)"}]" }
            formatted_unconnected = observingnode2rounds.to_a.map { |x| "#{x[0]} [#{x[1] / @@minutes_per_round} minutes]"}
            formatted_never_seen = target2neverseen[target]

            dst2filter_tracker[target] = SecondLevelFilterTracker.new(target, observingnode2rounds.keys, target2stillconnected[target])

            observingnode2rounds.keys.each do |src|
               srcdst2outage[[src,target]] = Outage.new(src, target, target2stillconnected[target],
                                                        formatted_connected, formatted_unconnected, formatted_never_seen)
               srcdst2outage[[src,target]].measurement_times << ["passed_first_lvl_filters", Time.new]
            end
        end

        # log first level filter stats
        log_filter_stats(filter_stats)
        
        [srcdst2outage, dst2filter_tracker]
    end

    def log_filter_stats(filter_stats)
        old_stats = []
        begin 
            old_stats = Marshal.load(IO.read(FailureIsolation::FirstLevelFilterStats))
        rescue
            $stderr.puts "Failed to load old isolation stats! #{$!}"
            old_stats = []
        end

        old_stats += filter_stats
        File.open(FailureIsolation::FirstLevelFilterStats, "w") { |f| f.write Marshal.dump(old_stats) }
    end
end


