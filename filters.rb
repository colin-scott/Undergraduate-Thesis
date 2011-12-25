#!/homes/network/revtr/ruby/bin/ruby

require 'filter_stats'
require 'failure_isolation_consts'
require 'set'

module Filters
    module Level
        CONNECTIVITY = :connectivity    # first level filters
        REGISTRATION= :registration     # registration filters
        MEASUREMENT = :measurement      # measurement filters
    end
    
    # Ordered levels
    Levels = [
        Level::CONNECTIVITY,
        Level::REGISTRATION,
        Level::MEASUREMENT
    ]

    def self.reason2level(reason)
        if FirstLevelFilters::TRIGGERS.include? reason
            return Level::CONNECTIVITY
        elsif RegistrationFilters::TRIGGERS.include? reason
            return Level::REGISTRATION
        elsif SecondLevelFilters::TRIGGERS.include? reason
            return Level::MEASUREMENT
        else
            raise "Unknown reason #{reason}"
        end
    end
end

module FirstLevelFilters
    LOWER_ROUNDS_BOUND = 4
    UPPER_ROUNDS_BOUND = 500
    VP_BOUND = 1

    NO_VP_HAS_CONNECTIVITY = :no_vp_has_connectivity
    NO_VP_RECENTLY_OBSERVING = :no_vp_recently_observing
    NO_STABLE_UNCONNECTED_VP = :no_stable_unconnected_vp
    NO_STABLE_CONNECTED_VP = :no_stable_connected_vp
    NO_NON_POISONER_OBSERVING = :no_non_poisoner
    NO_NON_POISONER_CONNECTED = :no_non_poisoner_connected
    NO_VP_REMAINS = :no_vp_remains
    ISSUED_MEASUREMENTS_RECENTLY = :issued_measurements_recently

    # The set of all filters this module can trigger
    TRIGGERS= Set.new([
        NO_VP_HAS_CONNECTIVITY,
        NO_VP_RECENTLY_OBSERVING,
        NO_STABLE_UNCONNECTED_VP,
        NO_STABLE_CONNECTED_VP,
        NO_NON_POISONER_OBSERVING,
        NO_NON_POISONER_CONNECTED,
        NO_VP_REMAINS,
        ISSUED_MEASUREMENTS_RECENTLY
    ])

    def self.filter!(target, filter_trackers, observingnode2rounds, neverseen, stillconnected,
                     nodetarget2lastoutage, nodetarget2lastisolationattempt, 
                     current_round, isolation_interval)
        # Pre: only filter trackers with target as dest
        now = Time.new
        nodes = observingnode2rounds.keys

        if self.no_vp_has_connectivity?(stillconnected)
            filter_trackers.each do |filter_tracker|
                filter_tracker.failure_reasons << NO_VP_HAS_CONNECTIVITY
            end
        end

        if self.no_stable_unconnected_vp?(observingnode2rounds)
            filter_trackers.each do |filter_tracker|
                filter_tracker.failure_reasons << NO_STABLE_UNCONNECTED_VP
            end
        end

        if self.no_stable_connected_vp?(stillconnected, nodetarget2lastoutage, target, now)
            filter_trackers.each do |filter_tracker|
                filter_tracker.failure_reasons << NO_STABLE_CONNECTED_VP 
            end
        end

        if self.no_non_poisoner_observing?(nodes)
            filter_trackers.each do |filter_tracker|
                filter_tracker.failure_reasons << NO_NON_POISONER_OBSERVING
            end
        end

        if self.no_non_poisoner_connected?(stillconnected)
            filter_trackers.each do |filter_tracker|
                filter_tracker.failure_reasons << NO_NON_POISONER_CONNECTED
            end
        end

        sources_already_used = self.check_recent_measurements(target, observingnode2rounds,
                                            nodetarget2lastisolationattempt, current_round, isolation_interval)

        filter_trackers.each do |filter_tracker|
            if sources_already_used.include? filter_tracker.source
                filter_tracker.failure_reasons << ISSUED_MEASUREMENTS_RECENTLY
            end
        end
    end
    
    # (at least one VP has connectivity)
    def self.no_vp_has_connectivity?(stillconnected)
        stillconnected.size < VP_BOUND
    end

    # (don't issue from nodes that have been experiencing the outage for a very long time)
    def self.no_vp_newly_observed?(observingnode2rounds)
        observingnode2rounds.delete_if { |node, rounds| rounds >= UPPER_ROUNDS_BOUND }.size < VP_BOUND
    end

    # (don't issue from nodes that just started seeing the outage)
    def self.no_stable_unconnected_vp?(observingnode2rounds)
        observingnode2rounds.delete_if { |node, rounds| rounds < LOWER_ROUNDS_BOUND }.size < VP_BOUND
    end

    # (at least one connected host has been consistently connected for at least 4 rounds)
    def self.no_stable_connected_vp?(stillconnected, nodetarget2lastoutage, target, now)
        stillconnected.find { |node| (now - (nodetarget2lastoutage[[node, target]] or Time.at(0))) / 60 > LOWER_ROUNDS_BOUND }.nil?
    end

    def self.no_non_poisoner_observing?(nodes)
        nodes.find { |n| !FailureIsolation::PoisonerNames.include? n }
    end

    def self.no_non_poisoner_connected?(stillconnected)
        stillconnected.find { |n| !FailureIsolation::PoisonerNames.include? n } 
    end

    def self.check_recent_measurements(target, observingnode2rounds, nodetarget2lastisolationattempt,
                                       current_round, isolation_interval)
        # Figure out whether any of the observing sources have recently issued
        # measurements for this target. If they have, exclude them. 
        affected_sources = Set.new

        # don't issue isolation measurements for targets which have
        # already been probed recently
        observingnode2rounds.each do |node, rounds|
            if nodetarget2lastisolationattempt.include? [node,target] and 
                        (current_round - nodetarget2lastisolationattempt[[node,target]] <= isolation_interval)
                observingnode2rounds.delete node 
                affected_sources.add node
            else
                nodetarget2lastisolationattempt[[node,target]] = current_round
            end
        end

        affected_sources
    end
end

# Filters out nodes that aren't registered with the controller, 
module RegistrationFilters
    SRC_NOT_REGISTERED = :source_not_registered 
    NO_REGISTERED_RECEIVERS = :no_receivers_registered

    TRIGGERS = Set.new([
        SRC_NOT_REGISTERED,
        NO_REGISTERED_RECEIVERS
    ])

    def self.filter!(srcdst2outage, srcdst2filter_tracker, registered_vps)
        now = Time.new

        srcdst2outage.each do |srcdst, outage|
            filter_tracker = srcdst2filter_tracker[srcdst]
            filter_tracker.registration_filter_time = now
            filter_tracker.registered_vps = registered_vps

            # Every outage object with the same target (dest) will have the same
            # set of receivers (connected nodes)
            if RegistrationFilters.no_registered_receivers?(outage.receivers, registered_vps)
                filter_tracker.failure_reasons << NO_REGISTERED_RECEIVERS
                srcdst2outage.delete srcdst
            end

            if RegistrationFilters.src_not_registered?(srcdst[0], registered_vps)
                filter_tracker.failure_reasons << SRC_NOT_REGISTERED
                srcdst2outage.delete srcdst
            end
        end
    end

    def self.src_not_registered?(src, registered_vps)
        !(registered_vps.include?(src))
    end

    def self.no_registered_receivers?(receivers, registered_vps)
        (receivers & registered_vps).empty?
    end
end


module SecondLevelFilters
   DEST_PINGABLE = :destination_pingable
   BOTH_DIRECTIONS_WORKING = :direction
   FWD_MEASUREMENTS_EMPTY = :forward_meas_empty
   TR_REACHED = :tr_reach 
   NO_HISTORICAL_TRACE = :no_hist 
   NO_PINGS = :no_ping 
   TR_REACHED_LAST_HOP = :tr_reached_last_hop 
   HISTORICAL_TR_NOT_REACH = :historical_tr_not_reach
   REVERSE_PATH_HELPLESS = :rev_path_helpess

   TRIGGERS = Set.new([
        DEST_PINGABLE,
        BOTH_DIRECTIONS_WORKING,
        FWD_MEASUREMENTS_EMPTY,
        TR_REACHED,
        NO_HISTORICAL_TRACE,
        NO_PINGS,
        TR_REACHED_LAST_HOP,
        HISTORICAL_TR_NOT_REACH,
        REVERSE_PATH_HELPLESS
   ])

   def self.filter!(outage, filter_tracker, ip_info, testing=false, file=nil, skip_hist_tr=false)
       # TODO: don't declare these variables like this... it's ugly
       src = outage.src
       dst = outage.dst 
       tr = outage.tr
       spoofed_tr = outage.spoofed_tr
       ping_responsive = outage.ping_responsive
       historical_tr = outage.historical_tr 
       historical_revtr = outage.historical_revtr
       direction = outage.direction

       filter_tracker.failure_reasons << BOTH_DIRECTIONS_WORKING if self.both_directions_working?(direction)
       filter_tracker.failure_reasons << FWD_MEASUREMENTS_EMPTY if self.forward_measurements_empty?(tr, spoofed_tr)
       filter_tracker.failure_reasons << TR_REACHED if self.tr_reached_dst_AS?(dst, tr, ip_info)
       filter_tracker.failure_reasons << DEST_PINGABLE if self.destination_pingable?(ping_responsive, dst, tr)
       filter_tracker.failure_reasons << NO_HISTORICAL_TRACE if self.no_historical_trace?(historical_tr, src, dst, skip_hist_tr)
       filter_tracker.failure_reasons << HISTORICAL_TR_NOT_REACH if self.historical_trace_didnt_reach?(historical_tr, src, skip_hist_tr)
       filter_tracker.failure_reasons << NO_PINGS if self.no_pings_at_all?(ping_responsive)
       filter_tracker.failure_reasons << TR_REACHED_LAST_HOP if self.tr_reached_last_hop?(historical_tr, tr)
       filter_tracker.failure_reasons << REVERSE_PATH_HELPLESS if self.reverse_path_helpless?(direction, historical_revtr) 

       outage.passed_filters = filter_tracker.passed?
   end

   def self.both_directions_working?(direction)
       direction == Direction.FALSE_POSITIVE
   end

   def self.forward_measurements_empty?(tr, spoofed_tr)
        # it's uninteresting if no measurements worked... probably the
        # source has no route
        forward_measurements_empty = (tr.size <= 1 && spoofed_tr.size <= 1)
   end

   def self.tr_reached_dst_AS?(dst, tr, ip_info)
        tr_reached_dst_AS = tr.reached_dst_AS?(dst, ip_info)
   end

   def self.destination_pingable?(ping_responsive, dst, tr)
        # sometimes we oddly find that the destination is pingable from the
        # source after isolation measurements have completed
        destination_pingable = ping_responsive.include?(dst) || tr.reached?(dst)
   end

   def self.no_historical_trace?(historical_tr, src, dst, skip_hist_tr=false)
        skip_hist_tr ||= FailureIsolation::PoisonerNames.include? src

        no_historical_trace = !skip_hist_tr and historical_tr.empty?

        return no_historical_trace
   end

   def self.historical_trace_didnt_reach?(historical_tr, src, skip_hist_tr=false)
       no_historical_trace = self.no_historical_trace?(historical_tr, src, skip_hist_tr)

       $stderr.puts "WTF? [-1] is nil, but not empty?" if historical_tr[-1].nil? and !historical_tr.empty?
       historical_trace_didnt_reach = !skip_hist_tr and !no_historical_trace && !historical_tr[-1].nil? and historical_tr[-1].ip == "0.0.0.0"
   end

   def self.no_pings_at_all?(ping_responsive)
        no_pings_at_all = (ping_responsive.empty?)
   end

   def self.tr_reached_last_hop?(historical_tr, tr)
        last_hop = (historical_tr.size > 1 && historical_tr[-2].ip == tr.last_non_zero_ip)
   end

   def self.reverse_path_helpless?(direction, historical_revtr) 
        # should we get rid of this after correlation?
        #reverse_path_helpless = (direction == Direction.REVERSE && !historical_revtr.valid?)
        # TODO: change me?
        reverse_path_helpless = false
   end
end

if __FILE__==  $0
    require 'hops'

    SecondLevelFilters.historical_trace_didnt_reach?(ForwardPath.new("poo", "face"), "poo")
end
