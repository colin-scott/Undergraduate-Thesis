
# First stage of the isolation pipeline.
# 
# Responsible for pulling state from ping monitors, classifying outages, and
# sending interesting outages to FailureDispatcher

require 'failure_dispatcher'
require 'house_cleaner'
require 'failure_isolation_consts'
require 'set'
require 'yaml'
require 'outage'
require 'filter_stats'
require 'isolation_utilities.rb'
require 'time'
require 'filters'

class FailureMonitor
    attr_accessor :dispatcher

    def initialize(dispatcher=FailureDispatcher.new, db=DatabaseInterface.new, logger=LoggerLog.new($stderr), house_cleaner=HouseCleaner.new, email="failures@cs.washington.edu")
        @dispatcher = dispatcher
        @db = db
        @logger = logger
        @email = email
        @house_cleaner = house_cleaner

        # TODO: handle these with optparse
        @@minutes_per_round = FailureIsolation::DefaultPeriodSeconds / 60

        # Max allowable lag for VP ping results before a VP is ignored
        @@max_ping_lag_seconds = 605

        # if a VP returns empty measurement results for more than 10 requests, swap it out
        @@failed_measurement_threshold = 10  

        # if more than 70% of a node's targets are unreachable, we ignore the
        # node
        @@source_specific_problem_threshold = 0.35

        # we send out faulty_node_audit reports thrice a day 
        # (there are 24*60/@@minutes_per_round rounds in a day -- so we want to 
        #  perform an audit report every 24*60/@@minutes_per_round/3 rounds)
        @@node_audit_period_rounds = 24*60/@@minutes_per_round/3

        @target_set_size = FailureIsolation.TargetSet.size

        # Persistent storage for { vp hostname -> [non-reachable target1, ... ]
        begin
            @vps_2_targets_never_seen = YAML.load_file(FailureIsolation::NonReachableTargetPath)
            raise unless @vps_2_targets_never_seen
        rescue Exception
            @vps_2_targets_never_seen = {}

            # unresponsive until proven otherwise
            FailureIsolation.CurrentNodes.each { |node| @vps_2_targets_never_seen[node.chomp] = FailureIsolation.TargetSet }
        end
        
        # Persistent storage for { [vp hostname, target] -> date of last observed outage }
        begin
            # [node, target] -> last time outage was observed
            @nodetarget2lastoutage = (File.readable? FailureIsolation::LastObservedOutagePath) ? YAML.load_file(FailureIsolation::LastObservedOutagePath) : {}
            raise unless @nodetarget2lastoutage.is_a?(Hash)
        rescue Exception
            @nodetarget2lastoutage = {}
        end

        # Nodes whose ping results are lagging
        @outdated_nodes = {}
        # Nodes seeing unreasonably many outages
        @problems_at_the_source = {}
        # Nodes not sshable from UW
        @not_sshable = Set.new

        # target -> time
        #  (so that we don't probe the hell out of failed routers)
        @nodetarget2lastisolationattempt = {}

        # minimum rounds in between successive isolation measurements sent from
        # a particular source to a particular destination
        @@isolation_interval_rounds = 3

        # current logical round
        @current_round = 0
    end

    # Make sure metadata persists between reboots
    #  (write out @vps_2_targets_never_seen and @nodetarget2lastoutage to a YAML file to be read in later)
    def persist_state
        File.open(FailureIsolation::NonReachableTargetPath, "w") { |f| YAML.dump(@vps_2_targets_never_seen, f) }
        File.open(FailureIsolation::LastObservedOutagePath, "w") { |f| YAML.dump(@nodetarget2lastoutage, f) }
    end

    # loop infinitely, periodically pulling state from ping monitors, and
    # sending interesting outages to FailureDispacher
    def start_pull_cycle()
        FileUtils.mkdir_p(FailureIsolation::PingStatePath) 

        loop do
            start = Time.new

            # ==================================== #                                                                                                                                 
            # Grab ping state                      #
            # ==================================== #                                                                                                                                 
            # TODO: cat directly from ssh rather than scp'ing
            # TODO: don't assume a single yml file -- need a better fetching mechanism
            # than pptasks
            
            # Get rid of old results
            FileUtils.rm_r(Dir.glob("#{FailureIsolation::PingStatePath}*yml"))
            # Get new results
            system "#{FailureIsolation::PPTASKS} scp #{FailureIsolation::MonitorSlice} #{FailureIsolation::CurrentNodesPath} 100 100 \
                     @:#{FailureIsolation::PingMonitorStatePath}*yml #{FailureIsolation::PingStatePath}"

            # NOTE: riot specific!
            system "scp cs@riot.cs.washington.edu:~/ping_monitors/*yml #{FailureIsolation::PingStatePath}"

            node2targetstate = read_in_results(start)

            update_auxiliary_state(node2targetstate)

            # ==================================== #                                                                                                                                 
            # Analyze ping state                   #
            # ==================================== #                                                                                                                                 
            target2observingnode2rounds, target2neverseen, target2stillconnected = classify_outages(node2targetstate)
            
            srcdst2outage, srcdst2filtertracker = filter_outages(target2observingnode2rounds, target2neverseen, target2stillconnected)

            # ==================================== #                                                                                                                                 
            # Send to FailureDispatcher            #
            # ==================================== #                                                                                                                                 
            @dispatcher.isolate_outages(srcdst2outage, srcdst2filtertracker)

            @logger.puts "round #{@current_round} completed"
            @current_round += 1
            
            clean_the_house if (@current_round % @@node_audit_period_rounds) == 0

            sleep_period = FailureIsolation::DefaultPeriodSeconds - (Time.new - start)
            @logger.info "Sleeping for #{sleep_period} seconds"

            sleep sleep_period if sleep_period > 0
        end
    end

    # ================================================= #                                                                                                                                 
    # Methods for retrieving ping state                 #
    # ================================================= #                                                                                                                                 
    
    def read_in_results(current_time)
        node2targetstate = {}

        # Note: PL nodes are on UTC. Note: -= creates a new Time object
        current_time -= current_time.gmt_offset

        num_behind_nodes = 0
        num_source_problems = 0

        @not_sshable = FailureIsolation.CurrentNodes.clone

        Dir.glob("#{FailureIsolation::PingStatePath}*yml").each do |yaml|
            node, mtime = parse_filename(yaml)
            next if node.nil?
            
            seconds_difference = (current_time - mtime).abs
            if seconds_difference >= @@max_ping_lag_seconds
                minutes_difference = seconds_difference / 60
                @outdated_nodes[node] = minutes_difference
                @logger.puts "#{node}'s data is #{minutes_difference} minutes out of date"
                num_behind_nodes += 1
                next
            end

            @not_sshable.delete node

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
            rescue Exception
                @logger.puts "Corrupt YAML file: #{node}"
                next
            end

            failure_percentage = hash.size * 1.0 / @target_set_size
            if (!FailureIsolation::PoisonerNames.include? node and failure_percentage > @@source_specific_problem_threshold) or
                    (FailureIsolation::PoisonerNames.include? node and failure_percentage == 1.0)
                @problems_at_the_source[node] = failure_percentage * 100
                @logger.puts "Problem at the source: #{node} #{@problems_at_the_source[node]}"
                num_source_problems += 1
                next
            end

            @outdated_nodes.delete node
            @problems_at_the_source.delete node
            node2targetstate[node] = hash
        end

        if num_behind_nodes == FailureIsolation.CurrentNodes.size or num_source_problems == FailureIsolation.CurrentNodes.size 
            Emailer.isolation_exception("Warning: all VPs were skipped due out of date ping state or high # of reported outages")
        end

        # nodes with problems at the source are excluded from node2targetstate
        node2targetstate
    end

    def parse_filename(yaml)
        begin
            # Format is: host_name++YYYY.MM.DD.HH.MM.SS.yml
            node, date = yaml.gsub(/.yml$/, "").split("++").map { |s| s.strip.downcase }
            node = File.basename node
            # Parse doesn't get MM.SS quite right -- Need to convert MM.SS to MM:SS
            up_to_year_index = "YYYY.HH.DD".size
            clock = date[(up_to_year_index+1)..-1].gsub(/\./, ":")
            date = date[0...up_to_year_index]
            mtime = Time.parse(date + " " + clock)
            return [node, mtime]
        rescue Exception => e
            Emailer.isolation_exception("unparseable filename #{yaml} #{e.backtrace}", "ikneaddough@gmail.com").deliver
            hostname = File.basename(yaml).gsub(/_target_state.yml$/, "")
            if hostname == "target_state.yml"
                hostname = `#{FailureIsolation::PPTASKS} ssh #{FailureIsolation::MonitorSlice} #{FailureIsolation::CurrentNodesPath} \
                                100 100 "if [ -f colin/target_state.yml ]; then hostname --fqdn; fi"`.split("\n").first
            end
            system "ssh uw_revtr2@#{hostname} pkill -9 -f ping_monitor_client.rb; rm colin/*rb"
            system "ssh cs@toil ~/colin/ping_monitoring/cloudfront_monitoring/restart_hosts.sh"
            return [nil, nil]
        end
    end
 
    # Update metadata at the beginning of each round
    def update_auxiliary_state(node2targetstate)
        current_time = Time.now

        node2targetstate.each do |node, target_state|
            target_state.keys.each do |target|
                @nodetarget2lastoutage[[node,target]] = current_time
            end

            # We updated nodes while isolation_module.rb was running...
            if @vps_2_targets_never_seen[node].nil?
                @vps_2_targets_never_seen[node] = FailureIsolation.TargetSet
            end

            if !@vps_2_targets_never_seen[node].empty?
                @vps_2_targets_never_seen[node] -= (FailureIsolation.TargetSet - Set.new(target_state.keys)) 
            end
        end
    end

    # ================================================= #                                                                                                                                 
    # Methods for processing ping state                 #
    # ================================================= #                                                                                                                                 

    # Given the ping state from all ping monitors, sanitize input, and
    # encapsulate state into Hashes
    #
    # Returns [target2observingnode2rounds, target2neverseen, target2stillconnected]
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
               next if FailureIsolation.TargetBlacklist.include? target

               if rounds.nil?
                   @logger.warn "#{node}: #{target} is nil..."
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

    # Apply first level filters, and instantiate Outage objects +
    # FilterTrackers for outages which passeed
    #
    # Returns [srcdst2outage, srcdst2filtertracker]
    def filter_outages(target2observingnode2rounds, target2neverseen, target2stillconnected)
        # For debugging:
        total_src_dsts = target2observingnode2rounds.values.reduce(0) { |sum,hash| sum + hash.size }

        # [node observing outage, target] -> outage struct
        srcdst2outage = {}
        srcdst2filtertracker = apply_first_lvl_filters!(target2observingnode2rounds, target2neverseen, target2stillconnected)

        if total_src_dsts != srcdst2filtertracker.size
            @logger.warn "total_src_dsts (#{total_src_dsts}) != srcdst2filterstracker.size (#{srcdst2filtertracker.size})"
        end

        now = Time.new

        target2observingnode2rounds.each do |target, observingnode2rounds|
            observingnode2rounds.keys.each do |src|
               srcdst = [src, target]
               filter_tracker = srcdst2filtertracker[srcdst]

               if filter_tracker.passed?
                  # convert still_connected to strings of the form
                  # "#{node} [#{time of last outage}"]"
                  #
                  # TODO: encpasulate VPs into objects, so to_s automatically
                  # yields the formatted string
                  formatted_connected = target2stillconnected[target].map { |node| "#{node} [#{@nodetarget2lastoutage[[node, target]] or "(n/a)"}]" }
                  formatted_unconnected = observingnode2rounds.to_a.map { |x| "#{x[0]} [#{x[1] / @@minutes_per_round} minutes]"}
                  formatted_never_seen = target2neverseen[target]

                  srcdst2outage[srcdst] = Outage.new(src, target, target2stillconnected[target],
                                                           formatted_connected, formatted_unconnected, formatted_never_seen)
                  srcdst2outage[srcdst].measurement_times << ["passed_first_lvl_filters", now]
               end
            end
        end

        [srcdst2outage, srcdst2filtertracker]
    end

    # Filter out instable and complete outages
    #
    # Note that this method modifies target2observingnode2rounds --
    # namely, it deletes all observing nodes that have recently issued
    # measurements for the target 
    def apply_first_lvl_filters!(target2observingnode2rounds, target2neverseen, target2stillconnected)
        now = Time.new
        srcdst2filtertracker = {}

        target2observingnode2rounds.each do |target, observingnode2rounds|
            stillconnected = target2stillconnected[target]
            neverseen = target2neverseen[target]

            filter_trackers_for_target = []

            observingnode2rounds.each do |node, rounds|
                filter_tracker = FilterTracker.new(node, target, stillconnected, now)
                srcdst2filtertracker[[node,target]] = filter_tracker
                filter_trackers_for_target << filter_tracker
            end

            FirstLevelFilters.filter!(target, filter_trackers_for_target, observingnode2rounds, neverseen, stillconnected,
                                      @nodetarget2lastoutage, @nodetarget2lastisolationattempt, @current_round, @@isolation_interval_rounds)
        end
        
        return srcdst2filtertracker
    end

    # ================================================= #                                                                                                                                 
    # Methods for filtering out faulty VPs and targets  # 
    # ================================================= #                                                                                                                                 

    # Every day, identify broken monitor VPs and unresponsive targets, replace
    # them, and send out a summary email
    def clean_the_house()
        Thread.new do
            swap_out_faulty_nodes
            swap_out_unresponsive_targets
        end
    end

    # Identify and swap out broken monitor VPs
    def swap_out_faulty_nodes()
        # First check if no nodes are left to swap out
        if (FailureIsolation.AllNodes - FailureIsolation.NodeBlacklist).empty?
            Emailer.isolation_exception("No nodes left to swap out!\nSee: #{FailureIsolation::NodeBlacklistPath}").deliver
            return
        end
        
        to_swap_out,outdated,source_problems,not_sshable,failed_measurements,
            not_controllable,bad_srcs,possibly_bad_srcs,outdated = identify_faulty_nodes

        @logger.debug "finished finding substitites for vps"

        Emailer.faulty_node_report(outdated,
                                   source_problems,
                                   not_sshable,
                                   not_controllable,
                                   failed_measurements,
                                   bad_srcs,
                                   possibly_bad_srcs).deliver

        return if to_swap_out.empty?

        @house_cleaner.swap_out_faulty_nodes(to_swap_out)
    end

    # Identify malfunctioning VPs
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

    # Identify unresponsive targets and update the target lists
    def swap_out_unresponsive_targets
        dataset2substitute_targets, dataset2unresponsive_targets, possibly_bad_targets, bad_hops, possibly_bad_hops = \
                @house_cleaner.find_substitutes_for_unresponsive_targets()
        @logger.debug "finished finding substitutes for targets"

        Emailer.isolation_status(dataset2unresponsive_targets, possibly_bad_targets, bad_hops, possibly_bad_hops).deliver
         
        @house_cleaner.swap_out_unresponsive_targets(dataset2unresponsive_targets, dataset2substitute_targets) 
    end
   
    # If signalled by an external program, remove a node from our metadata
    def remove_node(node)
        @nodetarget2lastoutage.delete_if { |n,t| n[0] == node }
        @vps_2_targets_never_seen.delete node
        @problems_at_the_source.delete node
        @outdated_nodes.delete node
        FailureIsolation.CurrentNodes.delete node
        @not_sshable.delete node
    end
end

