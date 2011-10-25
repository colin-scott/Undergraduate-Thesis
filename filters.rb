
module FirstLevelFilters
    UPPER_ROUNDS_BOUND = 500
    LOWER_ROUNDS_BOUND = 4
    VP_BOUND = 1

    NO_VP_HAS_CONNECTIVITY = :no_vp_has_connectivity
    NO_VP_RECENTLY_OBSERVING = :no_vp_recently_observing
    NO_STABLE_UNCONNECTED_VP = :no_stable_unconnected_vp
    NO_STABLE_CONNECTED_VP = :no_stable_connected_vp
    NO_NON_POISONER = :no_non_poisoner
    NO_VP_REMAINS = :no_vp_remains
    ALL_NODES_ISSUED_MEASUREMENTS_RECENTLY = :all_nodes_issued_measurements_recently
    
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

    # (if a poisoner is observing, make sure at least on other non-poinonser is also observing)
    def self.no_non_poisoner?(nodes)
       # if at least one poisoner, make sure at least one non-poisoner
       (nodes.find { |n| FailureIsolation::PoisonerNames.include? n }) ? nodes.find { |n| !FailureIsolation::PoisonerNames.include? n } : false
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

    def self.src_not_registered?(src, registered_vps)
        !(registered_vps.include?(src))
    end

    def self.no_registered_receivers?(receivers, registered_vps)
        (receivers & registered_vps).empty?
    end
end


module SecondLevelFilters
   def self.filter(outage, testing=false, file=nil, skip_hist_tr=false)
        src = outage.src
        dst = outage.dst 
        tr = outage.tr
        spoofed_tr = outage.spoofed_tr
        ping_responsive = outage.ping_responsive
        historical_tr = outage.historical_tr, 
        historical_revtr = outage.historical_revtr
        direction = outage.direction

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
   end

   def self.historical_trace_didnt_reach?(historical_tr, src, skip_hist_tr=false)
       no_historical_trace = self.no_historical_trace?(historical_tr, src, skip_hist_tr)

       historical_trace_didnt_reach = !skip_hist_tr and !no_historical_trace && historical_tr[-1].ip == "0.0.0.0"
        @logger.puts "no historical trace! #{src} #{dst}" if no_historical_trace
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



        if(!(testing || (!destination_pingable && direction != Direction.FALSE_POSITIVE &&
                !forward_measurements_empty && !tr_reached_dst_AS && !no_historical_trace && !no_pings_at_all && !last_hop &&
                !historical_trace_didnt_reach && !reverse_path_helpless)))

            bool_vector = { :destination_pingable => destination_pingable, :direction => direction == Direction.FALSE_POSITIVE, 
                :forward_meas_empty => forward_measurements_empty, :tr_reach => tr_reached_dst_AS, :no_hist => no_historical_trace, :no_ping => no_pings_at_all,
                :tr_reached_last_hop => last_hop, :historical_tr_not_reach => historical_trace_didnt_reach, :rev_path_helpess => reverse_path_helpless }

            @logger.puts "FAILED FILTERING HEURISTICS (#{src}, #{dst}, #{Time.new}#{(file.nil? ? "" : (", "+file)) }): #{bool_vector.inspect}"
            return [false, bool_vector]
        else
            return [true, {}]
        end
    end

end
