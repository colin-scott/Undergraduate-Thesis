#!/homes/network/revtr/ruby-upgrade/bin/ruby

# There are three levels of filters: 
#   - based on ping state: instable and non-complete outages 
#   - based on VP registration: outages where the relevant VPs aren't registered with the controller
#   - based on isolation measurements: outages which have resolved themselves,
#        or aren't otherwise interesting
#
# This file bundles all of the filters into one place for ease of maintanence

require 'filter_stats'
require 'failure_isolation_consts'
require 'set'

module Filters
    module Level
        CONNECTIVITY = :connectivity    # first level filters
        REGISTRATION = :registration     # registration filters
        MEASUREMENT = :measurement      # measurement filters
        SWAP = :swap                    # VPs were swappd out
    end
    
    # Ordered levels
    Levels = [
        Level::CONNECTIVITY,
        Level::REGISTRATION,
        Level::MEASUREMENT, 
        Level::SWAP
    ]

    def self.reason2level(reason)
        if FirstLevelFilters::TRIGGERS.include? reason
            return Level::CONNECTIVITY
        elsif RegistrationFilters::TRIGGERS.include? reason
            return Level::REGISTRATION
        elsif SecondLevelFilters::TRIGGERS.include? reason
            return Level::MEASUREMENT
        elsif SwapFilters::TRIGGERS.include? reason
            return Level::SWAP
        else
            raise "Unknown reason #{reason}"
        end
    end
end

module SwapFilters
    EMPTY_PINGS = :empty_pings

    TRIGGERS = Set.new([
        EMPTY_PINGS    
    ])

    def self.empty_pings!(outage, filter_tracker)
        filter_tracker.failure_reasons << EMPTY_PINGS
    end
end

module FirstLevelFilters
    # Minimum rounds a VP has observed ping loss
    LOWER_ROUNDS_BOUND = 4
    # Maximum rounds a VP has observed ping loss
    UPPER_ROUNDS_BOUND = 500
    # Minimum number of VPs observing the outage
    VP_BOUND = 1

    # Filter names
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

    # Run all first level filters. Mutates filter_trackers 
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
        observingnode2rounds.find_all { |node, rounds| rounds < UPPER_ROUNDS_BOUND }.size < VP_BOUND
    end

    # (don't issue from nodes that just started seeing the outage)
    def self.no_stable_unconnected_vp?(observingnode2rounds)
        observingnode2rounds.find_all{ |node, rounds| rounds >= LOWER_ROUNDS_BOUND }.size < VP_BOUND
    end

    # (at least one connected host has been consistently connected for at least 4 rounds)
    def self.no_stable_connected_vp?(stillconnected, nodetarget2lastoutage, target, now)
        stillconnected.find { |node| (now - (nodetarget2lastoutage[[node, target]] or Time.at(0))) / 60 > LOWER_ROUNDS_BOUND }.nil?
    end

    # BGP Mux nodes are a bit wonky -- they observe far more outages than the
    # other nodes. Make sure that the outage is legitimiate by ensuring that
    # at least one non BGP Mux node is observing
    def self.no_non_poisoner_observing?(nodes)
        not nodes.find { |n| not FailureIsolation::PoisonerNames.include? n }
    end

    # BGP Mux nodes are a bit wonky -- they observe far more outages than the
    # other nodes. Make sure that the outage is legitimiate by ensuring that
    # at least one non BGP Mux receiver has connectivity with the dest
    def self.no_non_poisoner_connected?(stillconnected)
        not stillconnected.find { |n| not FailureIsolation::PoisonerNames.include? n } 
    end

    # Figure out whether any of the observing sources have recently issued
    # measurements for this target. If they have, exclude them. 
    def self.check_recent_measurements(target, observingnode2rounds, nodetarget2lastisolationattempt,
                                       current_round, isolation_interval)
        affected_sources = Set.new

        # don't issue isolation measurements for targets which have
        # already been probed recently
        observingnode2rounds.each do |node, rounds|
            if nodetarget2lastisolationattempt.include? [node,target] and 
                        (current_round - nodetarget2lastisolationattempt[[node,target]] <= isolation_interval)
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
    # Filter names
    SRC_NOT_REGISTERED = :source_not_registered 
    NO_REGISTERED_RECEIVERS = :no_receivers_registered

    # The set of all filters this module can trigger
    TRIGGERS = Set.new([
        SRC_NOT_REGISTERED,
        NO_REGISTERED_RECEIVERS
    ])

    # Run all registration level filters. Mutates srcdst2filter_tracker and
    # srcdst2outage (removes outages which didn't pass)
    #
    # Pre: all filter trackers which passed have a corresponding outage object
    def self.filter!(srcdst2outage, srcdst2filter_tracker, registered_vps, house_cleaner)
        now = Time.new

        # list of sources that weren't registered (shouldn't ever happen)
        email_warnings = Set.new

        srcdst2outage.each do |srcdst, outage|
            filter_tracker = srcdst2filter_tracker[srcdst]
            filter_tracker.registration_filter_time = now
            filter_tracker.registered_vps = registered_vps

            # Note: every outage object with the same target (dest) will have the same
            # set of receivers (connected nodes)
            if RegistrationFilters.no_registered_receivers?(outage.receivers, registered_vps)
                filter_tracker.failure_reasons << NO_REGISTERED_RECEIVERS
                srcdst2outage.delete srcdst
            end

            if RegistrationFilters.src_not_registered?(srcdst[0], registered_vps)
                filter_tracker.failure_reasons << SRC_NOT_REGISTERED
                srcdst2outage.delete srcdst
                email_warnings << srcdst[0]
            end
        end

        # TODO: remove me when riot is running again
        email_warnings.delete_if { |src| FailureIsolation::PoisonerNames.include? src }

        if not email_warnings.empty?
            message = %{
                The following #{email_warnings.size}  ping monitors were not registered with the isolation controller:
                #{email_warnings.join "\n"}
            }
            
            Emailer.isolation_exception(message, "ikneaddough@gmail.com").deliver

            # and swap them out while we're at it, as long as we aren't
            # swapping out everyone, which indicates that something else is wrong
            if email_warnings.size <= 3
                house_cleaner.swap_out_faulty_nodes(email_warnings)
            end
        end
    end

    # Can't run isolation if the source is not responding to the controller!
    def self.src_not_registered?(src, registered_vps)
        not registered_vps.include?(src)
    end

    # Can't send spoofed probes if no conected nodes are responding to the controller!
    def self.no_registered_receivers?(receivers, registered_vps)
        (receivers & registered_vps).empty?
    end
end

# Filters applied after measurements have been gathered
module SecondLevelFilters
   # Filter names
   DEST_PINGABLE = :destination_pingable
   BOTH_DIRECTIONS_WORKING = :direction
   FWD_MEASUREMENTS_EMPTY = :forward_meas_empty
   TR_REACHED = :tr_reach 
   NO_HISTORICAL_TRACE = :no_hist 
   NO_PINGS = :no_ping 
   TR_REACHED_LAST_HOP = :tr_reached_last_hop 
   HISTORICAL_TR_NOT_REACH = :historical_tr_not_reach
   REVERSE_PATH_HELPLESS = :rev_path_helpess

   # The set of all filters this module can trigger
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

   # Run all second level filters. Mutates filter_tracker, and sets
   # outage.passed_filters
   def self.filter!(outage, filter_tracker, ip_info, file=nil, skip_hist_tr=true)
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

   # Outage may have resolved itself during measurement
   def self.both_directions_working?(direction)
       direction == Direction.FALSE_POSITIVE
   end

   # it's uninteresting if no measurements from the VP worked... probably the
   # source has no route
   def self.forward_measurements_empty?(tr, spoofed_tr)
        forward_measurements_empty = (tr.size <= 1 && spoofed_tr.size <= 1)
   end

   # Similiar to Hubble, if the traceroute from the source reached the
   # destination AS, we exclude the outage
   def self.tr_reached_dst_AS?(dst, tr, ip_info)
        tr_reached_dst_AS = tr.reached_dst_AS?(dst, ip_info)
   end

   # Outage may have resolved itself during measurement
   def self.destination_pingable?(ping_responsive, dst, tr)
        # sometimes we oddly find that the destination is pingable from the
        # source after isolation measurements have completed
        destination_pingable = ping_responsive.include?(dst) || tr.reached?(dst)
   end

   # We're flying blind without a historical traceroute. These should always
   # be present for functioning nodes anyway
   def self.no_historical_trace?(historical_tr, src, dst, skip_hist_tr=true)
        # Hack: BGP Mux nodes didn't have historical traces
        skip_hist_tr ||= FailureIsolation::PoisonerNames.include? src

        no_historical_trace = !skip_hist_tr and historical_tr.empty?

        return no_historical_trace
   end

   # VP /never/ reached the destination in the past! Note that historical
   # traces will always be chosen from the most recent trace that reached, and
   # only will result in a non-reaching trace if no historical trace reached.
   def self.historical_trace_didnt_reach?(historical_tr, src, skip_hist_tr=true)
       no_historical_trace = self.no_historical_trace?(historical_tr, src, skip_hist_tr)

       $stderr.puts "WTF? [-1] is nil, but not empty?" if historical_tr[-1].nil? and !historical_tr.empty?
       historical_trace_didnt_reach = !skip_hist_tr and !no_historical_trace and !historical_tr[-1].nil? and historical_tr[-1].ip == "0.0.0.0"
   end

   # it's uninteresting if no measurements from the VP worked... probably the
   # source has no route
   def self.no_pings_at_all?(ping_responsive)
        no_pings_at_all = (ping_responsive.empty?)
   end

   # TODO: this filter may be redundant with self.tr_reached_dst_AS?
   def self.tr_reached_last_hop?(historical_tr, tr)
        last_hop = (historical_tr.size > 1 && historical_tr[-2].ip == tr.last_non_zero_ip)
   end

   # For reverse path outages, we can't isolate with the old isolation
   # algorithm without a historical reverse path
   def self.reverse_path_helpless?(direction, historical_revtr) 
        # TODO: should we get rid of this after the correlation algorithm is
        # implemented?
        #reverse_path_helpless = (direction == Direction.REVERSE && !historical_revtr.valid?)
        reverse_path_helpless = false
   end
end

if __FILE__==  $0
    require 'hops'

    SecondLevelFilters.historical_trace_didnt_reach?(ForwardPath.new("poo", "face"), "poo")
end
