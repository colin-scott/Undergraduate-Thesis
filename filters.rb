require 'filter_stats'

module FirstLevelFilters
    UPPER_ROUNDS_BOUND = 500
    LOWER_ROUNDS_BOUND = 4
    VP_BOUND = 1

    NO_VP_HAS_CONNECTIVITY = :no_vp_has_connectivity
    NO_VP_RECENTLY_OBSERVING = :no_vp_recently_observing
    NO_STABLE_UNCONNECTED_VP = :no_stable_unconnected_vp
    NO_STABLE_CONNECTED_VP = :no_stable_connected_vp
    NO_NON_POISONER_OBSERVING = :no_non_poisoner
    NO_NON_POISONER_CONNECTED = :no_non_poisoner_connected
    NO_VP_REMAINS = :no_vp_remains
    ALL_NODES_ISSUED_MEASUREMENTS_RECENTLY = :all_nodes_issued_measurements_recently

    def self.filter(target, observingnode2rounds, stillconnected, nodetarget2lastoutage)
        now = Time.new
        nodes = observingnode2rounds.keys

        filter_tracker = FirstLevelFilterTracker.new(target, nodes, stillconnected, now)

        if self.no_vp_has_connectivity?(stillconnected)
            filter_tracker.failure_reasons << NO_VP_HAS_CONNECTIVITY
        end

        if self.no_stable_unconnected_vp?(observingnode2rounds)
            filter_tracker.failure_reasons << NO_STABLE_UNCONNECTED_VP
        end

        if self.no_stable_connected_vp?(stillconnected, nodetarget2lastoutage, target, now)
            filter_tracker.failure_reasons << NO_STABLE_CONNECTED_VP 
        end

        if self.no_non_poisoner_observing?(nodes)
            filter_tracker.failure_reasons << NO_NON_POISONER_OBSERVING
        end

        if self.no_non_poisoner_connected?(stillconnected)
            filter_tracker.failure_reasons << NO_NON_POISONER_CONNECTED
        end

        if self.no_vp_remains?(observingnode2rounds)
            filter_tracker.failure_reasons << NO_VP_REMAINS
        end
        
        return filter_tracker
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

    # (at least one observing node remains)
    def self.no_vp_remains?(observingnode2rounds)
       observingnode2rounds.empty? 
    end
end

# Filters out nodes that aren't registered with the controller, 
module RegistrationFilters
    SRC_NOT_REGISTERED = :source_not_registered 
    NO_REGISTERED_RECEIVERS = :no_receivers_registered

    def self.filter!(srcdst2outage, receivers, registered_vps)
        filter_list = RegistrationFilterList.new(Time.now, registered_vps)

        srcdst2outage.each do |srcdst, outage|
            filter_tracker = RegistrationFilterTracker.new(outage)
            if RegistrationFilters.src_not_registered?(srcdst[0], registered_vps)
               filter_tracker.failure_reasons << SRC_NOT_REGISTERED
            end

            if RegistrationFilters.no_registered_receivers?(outage.receivers, registered_vps)
               filter_tracker.failure_reasons << NO_REGISTERED_RECEIVERS
            end

            filter_list << filter_tracker

            if !filter_tracker.passed?
                srcdst2outage.delete srcdst
            end
        end
        
        return filter_list
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

   def self.filter(outage, filter_tracker, testing=false, file=nil, skip_hist_tr=false)
       # TODO: don't declare these variables like this... it's ugly
       src = outage.src
       dst = outage.dst 
       tr = outage.tr
       spoofed_tr = outage.spoofed_tr
       ping_responsive = outage.ping_responsive
       historical_tr = outage.historical_tr, 
       historical_revtr = outage.historical_revtr
       direction = outage.direction

       # Keep it as a hash for backwards compatibility
       failure_reasons = {}

       failure_reasons[BOTH_DIRECTIONS_WORKING] = self.both_directions_working?(direction)
       failure_reasons[FWD_MEASUREMENTS_EMPTY] = self.forward_measurements_empty?(tr, spoofed_tr)
       failure_reasons[TR_REACHED] = self.tr_reached_dst_AS?(dst, ip_info)
       failure_reasons[DEST_PINGABLE] = self.destination_pingable?(ping_responsive, dst, tr)
       failure_reasons[NO_HISTORICAL_TRACE] = self.no_historical_trace?(historical_tr, src, skip_hist_tr)
       failure_reasons[HISTORICAL_TR_NOT_REACH] =  self.historical_trace_didnt_reach?(historical_tr, src, skip_hist_tr)
       failure_reasons[NO_PINGS] =  self.no_pings_at_all?(ping_responsive)
       failure_reasons[TR_REACHED_LAST_HOP]  = self.tr_reached_last_hop?(historical_tr, tr)
       failure_reasons[REVERSE_PATH_HELPLESS] = self.reverse_path_helpless?(direction, historical_revtr) 

       filter_tracker.final_failed2reasons[src] = failure_reasons
       if filter_tracker.src_passed?(src)
          filter_tracker.final_passed << src 
          outage.passed_filters = true
       end
   end

   def self.both_directions_working?(direction)
       direction == Direction.FALSE_POSITIVE
   end

   def self.forward_measurements_empty?(tr, spoofed_tr)
        # it's uninteresting if no measurements worked... probably the
        # source has no route
        forward_measurements_empty = (tr.size <= 1 && spoofed_tr.size <= 1)
   end

   def self.tr_reached_dst_AS?(dst, ip_info)
        tr_reached_dst_AS = tr.reached_dst_AS?(dst, ip_info)
   end

   def self.destination_pingable?(ping_responsive, dst, tr)
        # sometimes we oddly find that the destination is pingable from the
        # source after isolation measurements have completed
        destination_pingable = ping_responsive.include?(dst) || tr.reached?(dst)
   end


   def self.no_historical_trace?(historical_tr, src, skip_hist_tr=false)
        skip_hist_tr ||= FailureIsolation::PoisonerNames.include? src

        no_historical_trace = !skip_hist_tr and historical_tr.empty?
        @logger.puts "no historical trace! #{src} #{dst}" if no_historical_trace

        return no_historical_trace
   end

   def self.historical_trace_didnt_reach?(historical_tr, src, skip_hist_tr=false)
       no_historical_trace = self.no_historical_trace?(historical_tr, src, skip_hist_tr)

       historical_trace_didnt_reach = !skip_hist_tr and !no_historical_trace && historical_tr[-1].ip == "0.0.0.0"
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
