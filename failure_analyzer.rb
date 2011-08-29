require 'isolation_module'
require 'ip_info'

class Direction
    # make initializer public during class loading (to deal with load ' ' calls)
    public_class_method :new

    def initialize(symbol)
        @symbol = symbol
    end

    @@forward = Direction.new(:"forward path")
    @@reverse = Direction.new(:"reverse path")
    @@both = Direction.new(:"bi-directional")
    @@false_positive = Direction.new(:"both paths seem to be working...?")

    def self.FORWARD
        return @@forward
    end

    def self.REVERSE
        return @@reverse
    end

    def self.BOTH
        return @@both
    end

    def self.FALSE_POSITIVE
        return @@false_positive
    end

    def to_s()
        @symbol.to_s
    end

    def is_forward?()
        return (self == Direction.FORWARD or self == Direction.BOTH)
    end

    def is_reverse?()
        return (self == Direction.REVERSE or self == Direction.BOTH)
    end

    private_class_method :new # singletons
end

class AlternatePath
    FORWARD = :"forward path"
    REVERSE = :"reverse path"
    HISTORICAL_REVERSE = :"historical reverse path"
    HISTORICAL_FORWARD = :"historical forward path"
end

# The "Brains" of the whole business. In charge of heuristcs for filtering,
# making sense of the measurements, etc.
#
# essentially, acts on Outage objects which already have data fields filled in
class FailureAnalyzer
    def initialize(ipInfo=IpInfo.new, logger=LoggerLog.new($stderr))
        @ipInfo = ipInfo
        @logger = logger

        @suspect_set_initializers = []
        @suspect_set_pruners = []
    end

    # initializer contract:
    #   - takes a MergedOutage object as param
    #   - returns a set of suspects
    def register_suspect_set_initializer(&initializer)
        @suspect_set_initializers << initializer
    end

    # pruner contract:
    #   - takes a set of suspects, and a MergedOutage object
    #   - prunes the set of suspects, and returns nil
    def register_suspect_set_pruner(&pruner)
        @suspect_set_pruners << pruner
    end

    # Huzzah, meta-programming
    def self.load_initializers_and_pruners_from_file(analyzer, file)
        require file

        Initializer.singleton_methods.each do |method_str|
            initializer = Initializer.method(method_str)
            analyzer.register_suspect_set_initializer(&initializer)
        end

        Pruner.singleton_methods.each do |method_str|
            pruner = Pruner.method(method_str)
            analyzer.register_suspect_set_pruner(&pruner)
        end
    end

    # returns the hop suspected to be close to the failure
    # Assumes only one failure in the network...
    def identify_faults(merged_outage)
        # OK, for now, always call initializers for both reverse and forward
        # path outages. They'll have to figure it out
        suspect_set = Set.new
        @suspect_set_initializers.each do |init| 
          suspect_set |= init.call merged_outage 
        end
        
        @suspect_set_pruners.each do |pruner|
          pruner.call suspect_set, merged_outage
        end
        
        merged_outage.suspected_failures[Direction.REVERSE] = suspect_set.to_a
        
        #if merged_outage.direction.is_reverse?
            #if !merged_outage.historical_revtr.valid?
            #    # let m be the first forward hop that does not yield a revtr to s
            #    tr_suspect = merged_outage.tr.last_responsive_hop
            #    spooftr_suspect = merged_outage.spoofed_tr.last_responsive_hop
            #    suspected_hop = Hop.later(tr_suspect, spooftr_suspect)
            #    merged_outage.suspected_failures[Direction.REVERSE] = [suspected_hop]

            #    # baaaaah. This is confusing and not all that helpful.
            #    #
            #    # do some comparison of m's historical reverse path to infer the router which is either
            #    # failed or changed its path
            #    #
            #    # doesn't make sense when running over logs... fine when run in
            #    # real-time though
            #    #
            #    # Will only have a historical_revtr if the suspected hop is a
            #    # historical hop, or the hops of the measured path overlap.
            #    # historical_revtr = fetch_historical_revtr(merged_outage.src, suspected_hop)
            #    # XXX 
            #    # return suspected_hop
            #else
            #    # TODO: more stuff with
            #    merged_outage.suspected_failures[Direction.REVERSE] = [merged_outage.historical_revtr.unresponsive_hop_farthest_from_dst()]
            #end # what if the spoofed revtr went through?
        #end

        # OK, for now, only call this on individual outages
        merged_outage.each do |outage|
            if outage.direction.is_forward?
                # the failure is most likely adjacent to the last responsive forward hop
                last_tr_hop = outage.tr.last_non_zero_hop
                last_spooftr_hop = outage.spoofed_tr.last_non_zero_hop
                suspected_hop = Hop.later(last_tr_hop, last_spooftr_hop)
                outage.suspected_failures[Direction.FORWARD] = [suspected_hop]
            end

            if outage.direction == Direction.FALSE_POSITIVE
                outage.suspected_failures[Direction.FALSE_POSITIVE] = [:"problem resolved itself"]
            end
        end

        merged_outage.suspected_failures[Direction.FORWARD] = merged_outage\
            .map { |o| o.suspected_failures[Direction.FORWARD] }.flatten.uniq.delete(nil)
    end

    # TODO: add as_hops_from_src to Hop objects
    def as_hops_from_src(suspected_hop, tr, spoofed_tr, historical_tr)
        as_hops_from_src = [count_AS_hops(tr, suspected_hop),
                count_AS_hops(spoofed_tr, suspected_hop),
                count_AS_hops(historical_tr, suspected_hop)].max
    end

    # TODO: add as_hops_from_dst to Hop objects
    def as_hops_from_dst(suspected_hop, historical_revtr, spoofed_revtr, spoofed_tr, tr, as_hops_from_src)
        metrics = [count_AS_hops(historical_revtr, suspected_hop),
                count_AS_hops(spoofed_revtr, suspected_hop)]
     
        if as_hops_from_src != -1
            metrics << spoofed_tr.compressed_as_path.length - as_hops_from_src
            metrics << tr.compressed_as_path.length - as_hops_from_src
        end
     
        metrics.max
    end

    # # AS hops from the first hop in the path until the suspected hop
    def count_AS_hops(path, suspected_hop)
        return -1 if path.empty? || !path.valid? || !suspected_hop.is_a?(Hop)

        as_count = 0
        prev_AS = path[0].asn

        if suspected_hop.asn.nil?
            for hop in path
               if hop.asn != prev_AS
                  prev_AS = hop.asn
                  as_count += 1
               end   

               if hop == suspected_hop
                  return as_count 
               end
            end

            return -1
        else
            for hop in path
               if hop.asn != prev_AS
                  prev_AS = hop.asn
                  as_count += 1
               end 

               if hop.asn == suspected_hop.asn
                   return as_count
               end
            end

            return -1
        end
    end

    def find_alternate_paths(src, dst, direction, tr, spoofed_tr, historical_tr,
                                      spoofed_revtr, historical_revtr)
        alternate_paths = []
     
        if(historical_revtr.ping_responsive_except_dst?(dst) && 
               historical_revtr.compressed_as_path != spoofed_revtr.compressed_as_path)
            alternate_paths << :"historical reverse path"
        end
    
        historical_as_path = historical_tr.compressed_as_path
        spoofed_as_path = spoofed_tr.compressed_as_path
        # if the spoofed_tr reached (reverse path problem), we compare the AS-level paths directly
        # if the spoofed_tr didn't reach, we compare up the interesction of
        # the two path. Both of these are subsumed by ([] & [])
        if(historical_tr.ping_responsive_except_dst?(dst) &&
               ((spoofed_as_path & historical_as_path) != spoofed_as_path))
            alternate_paths << :"historical forward path"
        end
    
        if(direction == Direction.FORWARD && measured_working_direction?(direction, spoofed_revtr))
            alternate_paths << :"reverse path"
        end
    
        if(direction == Direction.REVERSE && measured_working_direction?(direction, spoofed_tr))
            alternate_paths << :"forward path"
        end

        alternate_paths
    end

    def measured_working_direction?(direction, spoofed_revtr)
        case direction
        when Direction.FORWARD
            return (spoofed_revtr.valid?) ? spoofed_revtr.num_sym_assumptions : false
        when Direction.REVERSE
            return true # spoofed forward tr must have gone through
        else
            return false
        end
    end

    def path_changed?(historical_tr, tr, spoofed_tr, direction)
       case direction
       when Direction.REVERSE
       when Direction.FORWARD
       when Direction.BOTH
       when Direction.FALSE_POSITIVE
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
            direction = Direction.REVERSE
        elsif(reverse_problem and forward_problem)
            # failure is bidirectional
            direction = Direction.BOTH
        elsif(!reverse_problem and forward_problem)
            # failure is only on the forward path
            direction = Direction.FORWARD
        else
            # just a lossy link?
            direction = Direction.FALSE_POSITIVE
        end

        direction
    end

    def passes_filtering_heuristics?(src, dst, tr, spoofed_tr, ping_responsive, historical_tr, historical_revtr, direction, testing)
        # it's uninteresting if no measurements worked... probably the
        # source has no route
        forward_measurements_empty = (tr.size <= 1 && spoofed_tr.size <= 1)

        tr_reached_dst_AS = tr.reached_dst_AS?(dst, @ipInfo)

        # sometimes we oddly find that the destination is pingable from the
        # source after isolation measurements have completed
        destination_pingable = ping_responsive.include?(dst) || tr.reached?(dst)

        no_historical_trace = (historical_tr.empty?)

        historical_trace_didnt_reach = (!no_historical_trace && historical_tr[-1].ip == "0.0.0.0")

        @logger.puts "no historical trace! #{src} #{dst}" if no_historical_trace

        no_pings_at_all = (ping_responsive.empty?)

        last_hop = (historical_tr.size > 1 && historical_tr[-2].ip == tr.last_non_zero_ip)

        reverse_path_helpless = (direction == Direction.REVERSE && !historical_revtr.valid?)

        if(!(testing || (!destination_pingable && direction != Direction.FALSE_POSITIVE &&
                !forward_measurements_empty && !tr_reached_dst_AS && !no_historical_trace && !no_pings_at_all && !last_hop &&
                !historical_trace_didnt_reach && !reverse_path_helpless)))

            bool_vector = { :destination_pingable => destination_pingable, :direction => direction == Direction.FALSE_POSITIVE, 
                :forward_meas_essss => forward_measurements_empty, :tr_reach => tr_reached_dst_AS, :no_hist => no_historical_trace, :no_ping => no_pings_at_all,
                :tr_reached_last_hop => last_hop, :historical_tr_not_reach => historical_trace_didnt_reach, :rev_path_helpess => reverse_path_helpless }

            @logger.puts "FAILED FILTERING HEURISTICS (#{src}, #{dst}, #{Time.new}): #{bool_vector.inspect}"
            return [false, bool_vector]
        else
            return [true, {}]
        end
    end

    # TODO: get rid of Mock Hops!!!
    def categorize_failure(outage)
        if outage.direction == Direction.BOTH or outage.direction == Direction.FORWARD
            # Do the measured forward paths stop at the same hop? They should...
            last_tr_hop = outage.tr.last_responsive_hop
            last_spoofed_tr_hop = outage.spoofed_tr.last_responsive_hop

            # XXX what if they differ only by one hop? Who cares? It's still a
            # crystal clear forward path isolation
            #if !last_tr_hop.nil? && !last_spoofed_tr_hop.nil? && last_tr_hop.cluster != last_spoofed_tr_hop.cluster && (last_tr_hop.ttl - last_spoofed_tr_hop.ttl).abs > 1
            #   return :measured_forward_paths_differ
            #end
            
            if (last_tr_hop.nil? || last_tr_hop.is_a?(MockHop)) && (last_spoofed_tr_hop.nil? || last_spoofed_tr_hop.is_a?(MockHop))
                return :no_forward_path_at_all? # wtf??
            elsif (last_tr_hop.nil? || last_tr_hop.is_a?(MockHop))
                cluster = last_spoofed_tr_hop.cluster
            elsif (last_spoofed_tr_hop.nil? || last_spoofed_tr_hop.is_a?(MockHop))
                cluster = last_tr_hop.cluster
            else
                cluster = (last_spoofed_tr_hop.ttl > last_tr_hop.ttl) ? last_spoofed_tr_hop.cluster : last_tr_hop.cluster
            end

            # Does the historical forward path also pass through that last hop?
            same_last_hop = outage.historical_tr.find { |hop| !hop.is_a?(MockHop) && hop.cluster == cluster }
            return :forward_path_change unless same_last_hop

            if !same_last_hop.next.nil? && same_last_hop.next.no_longer_pingable?
                return :crytal_clear_forward_path
            else
                # TODO: consider wether next is in the same AS. Better if so
                #
                # BROKEN? do we arrive here if suspecteD_failure is nil?
                return :unclear_forward_path
            end
        else # Direction.REVERSE
            # is there a crystal clear "reachability horizon"?
            # This is easy to do visually. Several historical reverse paths,
            # all converging to one point, which is then pingable afterwards
            # TODO: factor in other nearby historical reverse paths
            
            # but how to do this in code?
            # I guess, is there a single point where hops before are pinable
            # and hops after aren't? Could be h
            if !outage.historical_revtr.valid?
                return :no_historical_revtr? # shouldn't have passed filtering heuristics...
            end

            # we didn't measure back from the destination, and the second hop
            # was ping responsive
            if !outage.historical_revtr.first_hop.no_longer_pingable?
                return :multi_homed_provider_link
            end

            last_unresponsive = outage.historical_revtr.unresponsive_hop_farthest_from_dst()
            if last_unresponsive.nil? && outage.historical_revtr.measured_from_destination?(outage.dst)
                return :all_but_dst_reachable_on_historical_revtr
            elsif last_unresponsive.nil?
                # we backed off the destination, and everyone was pingable, so
                # must be the access link
                return :multi_homed_provider_link
            end

            dst_as = @ipInfo.getASN(outage.dst)

            # TODO: how to get destination's ASN?
            if !dst_as.nil? && !last_unresponsive.previous.nil? && (last_unresponsive.asn == dst_as || last_unresponsive.previous.asn == dst_as)
                return :multi_homed_provider_link
            else # clear reachability horizon
                # confined to one AS?
                if last_unresponsive.on_as_boundary?
                    return :horizon_on_as_boundary
                else
                    return :clear_reachability_horizon
                end
            end

            #elsif last_unresponsive.find_subsequent { |hop| hop.no_longer_pingable? }
            #    return :no_clear_reachability_horizon
            
        end
    end

    def pingable_hops_beyond_failure(src, suspected_failure, direction, historical_tr)
        pingable_targets = []

        if (direction == Direction.FORWARD or direction == Direction.BOTH) and !suspected_failure.nil? and !suspected_failure.ttl.nil?
            pingable_targets += historical_tr.find_all { |hop| !hop.nil? && !hop.ttl.nil? && hop.ttl > suspected_failure.ttl && hop.ping_responsive }
        end

        pingable_targets
    end

    def pingable_hops_near_destination(src, historical_tr, spoofed_revtr, historical_revtr)
        pingable_targets = []

        pingable_targets += historical_revtr.all_hops_adjacent_to_dst_as.find_all { |hop| hop.ping_responsive }
        pingable_targets += spoofed_revtr.all_hops_adjacent_to_dst_as.find_all { |hop| hop.ping_responsive }

        return pingable_targets if historical_tr.empty?

        dst_as = historical_tr[-1].asn
        
        return pingable_targets if dst_as.nil?

        historical_tr.reverse.each do |hop|
            break if hop.asn != dst_as
            pingable_targets += hop.reverse_path.all_hops_adjacent_to_dst_as.find_all { |hop| hop.ping_responsive } unless hop.reverse_path.nil? or !hop.reverse_path.valid?
        end

        pingable_targets
    end
end
