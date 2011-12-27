#!/homes/network/revtr/ruby-upgrade/bin/ruby

# Performs analytics on isolation measurements. For example, this module implements the
# isolation algorithm.
#
# TODO: change method signatures to take a single outage or merged_outage
# object rather than (src, dst, tr, spoofed_tr, etc. etc.)

require 'failure_isolation_consts'
require 'ip_info'
require 'suspect_set_processors.rb'
require 'db_interface'
require 'direction'

# TODO: run the old isolation algorithm on outages... just b/c it's free, and we
# occasionally need it in the logs... ?

class AlternatePath
    # "Enum" for usable alternate paths between src and dst
    FORWARD = :"forward path"
    REVERSE = :"reverse path"
    HISTORICAL_REVERSE = :"historical reverse path"
    HISTORICAL_FORWARD = :"historical forward path"
end

# further defined in suspect_processors.rb
class Suspect
    # Encapsulates a single suspected failed router (IP address) initialized from a single 
    # Initializer method. A single IP address may appear in multiple Suspect
    # objects (if chosen by multiple Initializer methods)
    attr_accessor :initializer
end

class MergedSuspect
    # Encapsulates a single suspected failed router (IP address), along with all of the
    # (src, dst) outages for one round on which the suspected failed router appeared, as well
    # as all of the Initializer methods that chose it
    attr_accessor :ip, :outages, :initializers

    def initialize(suspects)
        raise "More than one IP found!" if suspects.map { |s| s.ip }.uniq.size > 1
        @ip = suspects.map { |s| s.ip }.flatten.first
        @outages = suspects.map { |s| s.outage }.uniq
        @initializers = suspects.map { |s| s.initializer }.uniq
    end

    def to_s()
        "#{ip} [Outage(s): #{outages.map { |o| o.to_s(false) }.join ' '}] {Initializer(s): #{initializers.join ' '}}"
    end
end

# The "Brains" of the whole business. In charge of heuristcs for filtering,
# making sense of the measurements, etc.
#
# essentially, acts on Outage objects which already have data fields filled in
class FailureAnalyzer
    def initialize(ipInfo=IpInfo.new, logger=LoggerLog.new($stderr), registrar=nil, db=DatabaseInterface.new)
        @ipInfo = ipInfo
        @logger = logger

        load_suspect_set_processors(ipInfo, logger, registrar, db)
    end

    # Grab initializer and pruner methods
    # TODO: reload me whenever the data is read in again
    def load_suspect_set_processors(ipInfo, logger, registrar, db)
        # Gather initializer methods from the Initializer class
        @initializer = Initializer.new(registrar, db, logger)
        # .public_methods(false) excludes superclass methods
        public_methods = @initializer.public_methods(false)
        @suspect_set_initializers = public_methods.uniq.map { |m| @initializer.method m }

        # Gather pruner methods from the Pruner class
        @pruner = Pruner.new(registrar, db, logger)
        # .public_methods(false) excludes superclass methods
        public_methods = @pruner.public_methods(false)
        Pruner::OrderedMethods.each { |method| public_methods.unshift method  }
        @suspect_set_pruners = public_methods.uniq.map { |m| @pruner.method m }
    end

    # New isolation algorithm. Generates a suspect set and prunes that
    # suspect set.
    #
    # Note: also runs the old isolation algorithm for individual (src, dst)
    # outages (just because it doesn't incur any additional measurements)
    #
    # TODO: use old isolation algorithm for poisining experiments, since new
    # isolation algorithm isn't robust enough for poisoning yet.
    def identify_faults(merged_outage)
        if merged_outage.direction != Direction.FORWARD
            # For bi-directional or reverse outages, execute the
            # suspect set -> prune algorithm
            ip2suspects = Hash.new { |h,k| h[k] = [] }
            # initialize suspect set
            all_suspect_ips, initial_suspect_ips = initialize_suspect_set(merged_outage, ip2suspects)
            # prune suspect set
            prune_suspect_set(merged_outage, all_suspect_ips)

            # Note: all_suspect_set_ips is modified in prune_suspect_set()
            removed_ips = initial_suspect_ips - all_suspect_ips
            @logger.debug "removed_ips #{removed_ips.inspect}"
             
            # Combine suspects that are common to multiple (src, dst) outages
            merged_remaining_suspects = ip2suspects.find_all { |ip, suspects| !removed_ips.include? ip }.map { |k,v| MergedSuspect.new(v) }
            merged_outage.suspected_failures[Direction.REVERSE] = merged_remaining_suspects
        end

        # For forward + bidirectional outages, identify the first unreachable
        # hops for each (src, dst) outage
        
        # run the old isolation algorithm on individual (src, dst) pairs
        merged_outage.each do |outage|
            identify_fault_single_outage(outage)
        end

        # Forward suspects are the union of first unreachable hops for each
        # (src, dst) forward or bidirectional outage
        #       (computed by identify_fault_single_outage())
        merged_outage.suspected_failures[Direction.FORWARD] = merged_outage\
            .map { |o| (o.suspected_failures[Direction.FORWARD] or o.suspected_failures[Direction.FALSE_POSITIVE]) }.flatten.uniq

        merged_outage.suspected_failures[Direction.FORWARD] |= []

        # XXX Why won't the html in the email display the name of the class... only the
        # '#' ...........
        merged_outage.suspected_failures[Direction.FORWARD].delete(nil)
    end

    # Initialize the suspect set for a given merged_outage
    #
    # Return [all_suspect_ips, initial_suspect_ips]
    #       (which are initially clones of eachother)
    #
    # Also fill in the ip -> Suspect hash
    def initialize_suspect_set(merged_outage, ip2suspects)
        initializer2suspectset = {}

        @suspect_set_initializers.each do |init|
            # Gather suspects for initializer
            suspects = Set.new(init.call merged_outage)
            initializer_name = init.to_s

            suspects.each do |s|
                # add in the initializer to the suspect object
                s.initializer = initializer_name
                # add suspect to ips
                ip2suspects[s.ip] << s
            end

            initializer2suspectset[initializer_name] = suspects
        end

        # TODO: we should display # unique targets added in emails...
        #     can be computed via the ordering of suspect set initializers
        all_suspect_ips = Set.new(ip2suspects.keys)
        initial_suspect_ips = all_suspect_ips.clone 

        @logger.debug "all_suspect_ips size : #{all_suspect_ips.size}"
        @logger.debug "initializer2suspectset : #{initializer2suspectset.values.map { |set| set.to_a.map { |s| s.ip }}.flatten.uniq.size}"

        merged_outage.initializer2suspectset = initializer2suspectset

        return [all_suspect_ips, initial_suspect_ips]
    end

    # Prune the suspect set for a given merged_outage using the Pruner methods
    #
    # Sets merged_outage.pruner2incount_removed, a hash from:
    #   { name of pruner method -> [# of suspects given to pruner, list of pruned suspects]
    #
    # Note that list of pruned suspects only includes hops which were not
    # previously pruned by other pruners
    def prune_suspect_set(merged_outage, all_suspect_ips)
        pruner2incount_removed = {}
        @suspect_set_pruners.each do |pruner|
            break if all_suspect_ips.empty?
            removed = pruner.call all_suspect_ips.clone, merged_outage
            #raise "not properly formatted pruner response #{removed.inspect}" if !removed.respond_to?(:find) or removed.find { |hop| !hop.is_a?(String) or !hop.matches_ip? }
            pruner2incount_removed[pruner.to_s] = [all_suspect_ips.size, removed & all_suspect_ips]
            all_suspect_ips -= removed
        end

        merged_outage.pruner2incount_removed = pruner2incount_removed
    end

    # The old isolation algorithm. Acts on a single (src, dst) outage. For forward + bidirectional outages, 
    # identify the unreachable hop adjacent to the last responsive forward hop. For reverse + bidirectional
    # outages, identify the unresponsive hop on the historical revtr furthest
    # from the destination.
    def identify_fault_single_outage(outage)
        if outage.direction.is_forward?
            # the failure is most likely adjacent to the last responsive forward hop
            last_tr_hop = outage.tr.last_non_zero_hop
            last_spooftr_hop = outage.spoofed_tr.last_non_zero_hop
            suspected_hop = Hop.later(last_tr_hop, last_spooftr_hop)
            outage.suspected_failures[Direction.FORWARD] = [suspected_hop] unless suspected_hop.nil?
        end

        # note: is_reverse? and is_forward? both return true for bidirectional
        # outages. This implies that bidirectional outages will have non-empty
        # suspected_failures[Direction.REVERSE] and
        # suspected_failres[Direction.FORWARD]
        if outage.direction.is_reverse?
            reverse_isolation_single_outage(outage)
        end

        if outage.direction == Direction.FALSE_POSITIVE
            outage.suspected_failures[Direction.FALSE_POSITIVE] = [:"problem resolved itself"]
        end
    end

    # Old isolation algorithm for reverse + bidirectional outages. Find the unresponsive hop
    # on the historical revtr farthest from the destination.
    #
    # If the historical revtr is not valid, suspect list is empty.
    def reverse_isolation_single_outage(outage)
        if !outage.historical_revtr.valid?
            outage.suspected_failures[Direction.REVERSE] = []
            outage.complete_reverse_isolation = false
        else
            outage.suspected_failures[Direction.REVERSE] = [outage.historical_revtr.unresponsive_hop_farthest_from_dst()]
            outage.complete_reverse_isolation = true
        end # TODO: what if the spoofed revtr went through for a reverse path outage? It shouldn't, but it could.
    end

    # Return the number of AS hops the suspected failure is from the
    # source. (Not really that useful...)
    #
    # TODO: move as_hops_from_src to the Hop class
    def as_hops_from_src(suspected_hop, tr, spoofed_tr, historical_tr)
        as_hops_from_src = [count_AS_hops(tr, suspected_hop),
                count_AS_hops(spoofed_tr, suspected_hop),
                count_AS_hops(historical_tr, suspected_hop)].max
    end

    # Return the number of AS hops the suspected failure is from the
    # destination. (Not really that useful...)
    #
    # TODO: move as_hops_from_src to the Hop class
    def as_hops_from_dst(suspected_hop, historical_revtr, spoofed_revtr, spoofed_tr, tr, as_hops_from_src)
        metrics = [count_AS_hops(historical_revtr, suspected_hop),
                count_AS_hops(spoofed_revtr, suspected_hop)]
     
        if as_hops_from_src != -1
            metrics << spoofed_tr.compressed_as_path.length - as_hops_from_src
            metrics << tr.compressed_as_path.length - as_hops_from_src
        end
     
        metrics.max
    end

    # Count the number of AS hops form the path's source to the
    # suspected_hop's ASN
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

    # Return the alternate paths that may be usable by the source or
    # destination. The naive algorithm for now is to check pingability for
    # every hop along the historical forward and reverse paths.
    # Paths measured succesfully in working direction for uni-directional
    # outages are included as well.
    def find_alternate_paths(src, dst, direction, tr, spoofed_tr, historical_tr,
                                      spoofed_revtr, historical_revtr)
        alternate_paths = []
     
        # Check historical reverse path
        if(historical_revtr.ping_responsive_except_dst?(dst) && 
               historical_revtr.compressed_as_path != spoofed_revtr.compressed_as_path)
            # the destination won't be pingable, by our definition of outage.
            # If the historical_revtr is exactly the same (at the ASN level) as the measured
            # reverse path, only include the measured reverse path.
            alternate_paths << :"historical reverse path"
        end
    
        # Check historical forward path
        historical_as_path = historical_tr.compressed_as_path
        spoofed_as_path = spoofed_tr.compressed_as_path
        if(historical_tr.ping_responsive_except_dst?(dst) &&
               ((spoofed_as_path & historical_as_path) != spoofed_as_path))
            # the desintaion won't be pingable by our definition of outage.
            # IF the historical forward path is exactly the same (at the ASN
            # level) as the measured forward path, only include the measured forward path. In particular:
            #
            #   if the spoofed_tr reached (reverse path problem), we compare the AS-level paths of the historical traceroute and
            #   measured traceroute directly.
            #
            #   if the spoofed_tr didn't reach, we compare up the interesction of
            #   the two paths. Both of these are subsumed by ([] & [])
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

    # Return whether one of the directions was measured succesfully (for
    # uni-directional outages)
    #
    # We use an arbitrary of "measured succesfully" for spoofed revtrs: must
    # have <= a certain number of symmetry assumptions
    def measured_working_direction?(direction, spoofed_revtr)
        case direction
        when Direction.FORWARD
            return (spoofed_revtr.valid?) ? spoofed_revtr.num_sym_assumptions : false
        when Direction.REVERSE
            return true # spoofed forward tr must have gone through, by definition
        else
            return false # bi-directional not measured, by definition
        end
    end

    # Return whether the measured path has changed from the historical path
    #
    # TODO: not yet implemented!
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

    # Return the direction of the outage, given whether the forward + reverse
    # paths were measured successfully
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

    # Return whether the outage passes second level filters
    #
    # TODO: get rid of testing flag
    def passes_filtering_heuristics?(outage, filter_tracker, testing=false, file=nil, skip_hist_tr=false)
        SecondLevelFilters.filter!(outage, filter_tracker, @ipInfo, testing, file, skip_hist_tr) 
        return outage.passed_filters
    end

    # Place the outage into a categoriazation bucket. See Section 5 of senior
    # thesis for more info.
    #
    # TODO: get rid of Mock Hops! they were originally used for dot diagrams,
    # but are no longer needed.
    #
    # TODO: factor out return value symbols into their own "enum" class
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

    # Return the hops along the forward path(s) beyond the suspected failure which are pingable from the
    # source
    def pingable_hops_beyond_failure(src, suspected_failure, direction, historical_tr)
        pingable_targets = []

        if (direction == Direction.FORWARD or direction == Direction.BOTH) and !suspected_failure.nil? and !suspected_failure.ttl.nil?
            pingable_targets += historical_tr.find_all { |hop| !hop.nil? && !hop.ttl.nil? && hop.ttl > suspected_failure.ttl && hop.ping_responsive }
        end

        pingable_targets
    end

    # Return a list of the gateway routers along reverse path(s) which are pingable from the
    # source, and directly adjacent to the destination's AS
    def pingable_hops_near_destination(src, historical_tr, spoofed_revtr, historical_revtr)
        pingable_targets = []

        pingable_targets += historical_revtr.all_hops_adjacent_to_dst_as.find_all { |hop| hop.ping_responsive }
        pingable_targets += spoofed_revtr.all_hops_adjacent_to_dst_as.find_all { |hop| hop.ping_responsive }

        return pingable_targets if historical_tr.empty?

        dst_as = historical_tr[-1].asn
        
        return pingable_targets if dst_as.nil?

        historical_tr.reverse.each do |hop|
            break if hop.asn != dst_as
            pingable_targets += hop.reverse_path.all_hops_adjacent_to_dst_as.find_all { |h| h.ping_responsive } unless hop.reverse_path.nil? or !hop.reverse_path.valid?
        end

        pingable_targets
    end
end

if $0 == __FILE__
    FailureAnalyzer.new
end
