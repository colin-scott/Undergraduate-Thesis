require 'isolation_module'

class Direction
    FORWARD = "forward path"
    REVERSE = "reverse path"
    BOTH = "bi-directional"
    FALSE_POSITIVE = "both paths seem to be working...?"
end

# The "Brains" of the whole business. In charge of heuristcs for filtering,
# making sense of the measurements, etc.
class FailureAnalyzer
    def initialize(ipInfo)
        @ipInfo = ipInfo
    end

    # returns the hop suspected to be close to the failure
    # Assumes only one failure in the network...
    def identify_fault(src, dst, direction, tr, spoofed_tr, historical_tr,
                                      spoofed_revtr, historical_revtr)
        case direction
        when Direction::REVERSE
            # let m be the first forward hop that does not yield a revtr to s
            tr_suspect = tr.last_responsive_hop
            spooftr_suspect = spoofed_tr.last_responsive_hop
            suspected_hop = Hop.later(tr_suspect, spooftr_suspect)
            return nil if suspected_hop.nil?
            
            # do some comparison of m's historical reverse path to infer the router which is either
            # failed or changed its path
            #
            # doesn't make sense when running over logs... fine when run in
            # real-time though
            # historical_revtr = fetch_cached_revtr(src, suspected_hop)
            # XXX 
            return suspected_hop
        when Direction::FORWARD, Direction::BOTH
            # the failure is most likely adjacent to the last responsive forward hop
            last_tr_hop = tr.last_non_zero_hop
            last_spooftr_hop = spoofed_tr.last_non_zero_hop
            suspected_hop = Hop.later(last_tr_hop, last_spooftr_hop)
            return suspected_hop
        when Direction::FALSE_POSITIVE
            return "problem resolved itself"
        else 
            raise "unknown direction #{direction}!"
        end
     
        # TODO: how many sources away from the source/dest is the failure?
    end

    def find_working_historical_paths(src, dst, direction, tr, spoofed_tr, historical_tr,
                                      spoofed_revtr, historical_revtr)
        alternate_paths = []
     
        if(historical_reverse.ping_responsive_except_dst?(dst) && 
               historical_reverse.as_path != spoofed_revtr.as_path)
            alternate_paths << :"historical reverse path"
        end
    
        historical_as_path = historical_tr.as_path
        spoofed_as_path = spoofed_tr.as_path
        # if the spoofed_tr reached (reverse path problem), we compare the AS-level paths directly
        # if the spoofed_tr didn't reach, we compare up the interesction of
        # the two path. Both of these are subsumed by ([] & [])
        if(historical_tr.ping_responsive_except_dst?(dst) &&
               ((spoofed_as_path & historical_as_path) != spoofed_as_path)
            alternate_paths << :"historical forward path"
        end
    
        if(direction == Direction::FORWARD && measured_working_direction?(direction, spoofed_revtr))
            alternate_paths << :"reverse path"
        end
    
        if(direction == Direction::REVERSE && measured_working_direction?(direction, spoofed_tr))
            alternate_paths << :"forward path"
        end

        alternate_paths
    end

    def measured_working_direction?(direction, spoofed_revtr)
        case direction
        when Direction::FORWARD
            return spoofed_revtr.successful?
        when Direction::REVERSE
            return true # spoofed forward tr must have gone through
        else
            return false
        end
    end

    def path_changed?()
       case direction
       when Direction::REVERSE
       when Direction::FORWARD
       when Direction::BOTH
       when Direction::FALSE_POSITIVE
       else
       end

       return false
    end

    def compare_ground_truth(src, dst, direction, tr, spoofed_tr, historical_tr,
                                      spoofed_revtr, historical_revtr, dst_tr, dst_spoofed_tr)
        # we can probably do this post-hoc 
    end

    def infer_direction(reverse_problem, forward_problem)
        if(reverse_problem and !forward_problem)
            # failure is only on the reverse path
            direction = Direction::REVERSE
        elsif(reverse_problem and forward_problem)
            # failure is bidirectional
            direction = Direction::BOTH
        elsif(!reverse_problem and forward_problem)
            # failure is only on the forward path
            direction = Direction::FORWARD
        else
            # just a lossy link?
            direction = Direction::FALSE_POSITIVE
        end

        direction
    end

    def passes_filtering_heuristics?(src, dst, tr, spoofed_tr, ping_responsive, historical_tr, direction, testing)
        # it's uninteresting if no measurements worked... probably the
        # source has no route
        forward_measurements_empty = (tr.size <= 1 && spoofed_tr.size <= 1)

        tr_reached_dst_AS = tr.reached_dst_AS?(dst, @ipInfo)

        # sometimes we oddly find that the destination is pingable from the
        # source after isolation measurements have completed
        destination_pingable = ping_responsive.include?(dst) || tr.reached?(dst)

        #no_historical_trace = (historical_tr.empty?)
        no_historical_trace = false # XXX    just to see if more emails show up...

        # $LOG.puts "no historical trace! #{src} #{dst}" if no_historical_trace

        no_pings_at_all = (ping_responsive.empty?)

        if(!(testing || (!destination_pingable && direction != Direction::FALSE_POSITIVE &&
                !forward_measurements_empty && !tr_reached_dst_AS && !no_historical_trace && !no_pings_at_all)))

            bool_vector = { :dp => !destination_pingable, :dir => direction != Direction::FALSE_POSITIVE, 
                :f_empty => !forward_measurements_empty, :tr_reach => !tr_reached_dst_AS, :no_hist => !no_historical_trace, :no_ping => !no_pings_at_all}

            $LOG.puts "FAILED FILTERING HEURISTICS (#{src}, #{dst}, #{Time.new}): #{bool_vector.inspect}"
            return false
        else
            return true
        end
    end
end
