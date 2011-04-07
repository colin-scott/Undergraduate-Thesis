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
            tr_suspect = find_last_responsive_hop(tr)
            spooftr_suspect = find_last_responsive_hop(spoofed_tr)
            suspected_hop = later_hop(tr_suspect, spooftr_suspect)
            return nil if suspected_hop.nil?
            
            # do some comparison of m's historical reverse path to infer the router which is either
            # failed or changed its path
            #
            # doesn't make sense when running over logs... fine when run in
            # real-time though
            # historical_revtr = fetch_cached_revtr(src, suspected_hop) unless suspected_hop.nil? 
            # XXX 
            return suspected_hop
        when Direction::FORWARD, Direction::BOTH
            # the failure is most likely adjacent to the last responsive forward hop
            last_tr_hop = find_last_non_zero_hop_of_tr(tr)
            last_spooftr_hop = find_last_non_zero_hop_of_tr(spoofed_tr)
            suspected_hop = later_hop(last_tr_hop, last_spooftr_hop)
            return suspected_hop
        when Direction::FALSE_POSITIVE
            return "problem resolved itself"
        else 
            raise "unknown direction #{direction}!"
        end

        # TODO: how many sources away from the source/dest is the failure?
    end

    def later_hop(tr_suspect, spooftr_suspect)
        if tr_suspect.nil?
            return spooftr_suspect
        elsif spooftr_suspect.nil?
            return tr_suspect
        else
            return (tr_suspect.ttl > spooftr_suspect.ttl) ? tr_suspect : spooftr_suspect
        end
    end

    def find_last_responsive_hop(path)
        path.reverse.find { |hop| !hop.is_a?(MockHop) && hop.ping_responsive && hop.ip != "0.0.0.0" }
    end

    def find_working_historical_paths(src, dst, direction, tr, spoofed_tr, historical_tr,
                                      spoofed_revtr, historical_revtr)
        case direction
        when Direction::REVERSE
        when Direction::FORWARD
          #   we might also send pings to historical forward hops to see if the path has changed
        when Direction::FALSE_POSITIVE
        else 
        end
    end

    def measured_working_direction?(src, dst, direction, tr, spoofed_tr, historical_tr,
                                      spoofed_revtr, historical_revtr)
       case direction
       when Direction::FORWARD
           # Damn, I hate that hack. .is_a(Symbol)... all because I wanted to
           # format the html easily
           return !spoofed_revtr[0].is_a?(Symbol) # Ummm, what about symmetry assumptions...
       when Direction::REVERSE
           return forward_path_reached?(spoofed_tr)
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
    end

    def compare_ground_truth(src, dst, direction, tr, spoofed_tr, historical_tr,
                                      spoofed_revtr, historical_revtr, dst_tr, dst_spoofed_tr)
        
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

    def tr_reached_dst_AS?(dst, tr)
        dest_as = @ipInfo.getASN(dst)
        last_non_zero_hop = find_last_non_zero_ip_of_tr(tr)
        last_hop_as = (last_non_zero_hop.nil?) ? nil : @ipInfo.getASN(last_non_zero_hop)
        return !dest_as.nil? && !last_hop_as.nil? && dest_as == last_hop_as
    end

    def find_last_non_zero_ip_of_tr(tr)
        hop = find_last_non_zero_hop_of_tr(tr)
        return (hop.nil?) ? nil : hop.ip
    end

    def find_last_non_zero_hop_of_tr(tr)
        last_hop = tr.reverse.find { |hop| hop.ip != "0.0.0.0" }
        return (last_hop.nil? || last_hop.is_a?(MockHop)) ? nil : last_hop
    end

    def forward_path_reached?(path, dst)
        !path.find { |hop| hop.ip == dst }.nil?
    end

    def passes_filtering_heuristics(src, dst, tr, spoofed_tr, ping_responsive, historical_tr_hops, direction, testing)
        # it's uninteresting if no measurements worked... probably the
        # source has no route
        forward_measurements_empty = (tr.size <= 1 && spoofed_tr.size <= 1)

        tr_reached_dst_AS = tr_reached_dst_AS?(dst, tr)

        # sometimes we oddly find that the destination is pingable from the
        # source after isolation measurements have completed
        destination_pingable = ping_responsive.include?(dst) || forward_path_reached?(tr, dst)

        no_historical_trace = (historical_tr_hops.empty?)

        # $LOG.puts "no historical trace! #{src} #{dst}" if no_historical_trace

        no_pings_at_all = (ping_responsive.empty?)

        if(!(testing || (!destination_pingable && direction != Direction::FALSE_POSITIVE &&
                !forward_measurements_empty && !tr_reached_dst_as && !no_historical_trace && !no_pings_at_all)))

            bool_vector = { :dp => !destination_pingable, :dir => direction != Direction::FALSE_POSITIVE, 
                :f_empty => !forward_measurements_empty, :tr_reach => !tr_reached_dst_as, :no_hist => !no_historical_trace, :no_ping => !no_pings_at_all}

            $LOG.puts "FAILED FILTERING HEURISTICS (#{src}, #{dst}, #{Time.new}): #{bool_vector.inspect}"
            return false
        else
            return true
        end
    end
end
