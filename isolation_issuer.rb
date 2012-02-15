#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << "./"

require 'set'
require 'isolation_utilities'
require 'failure_isolation_consts'
require 'measurement_issuers'

# Isolation system's interface for measurement requests, parsing results, and
# returning encapsulated path objects
class MeasurementRequestor
    def initialize(logger=LoggerLog.new($stderr),ip_info=IpInfo.new)
        @logger = logger
        @ip_info = ip_info
        # Only allow one thread at a time to issue spoofed traceroutes (needed
        # since spoofer ids must be unique. TODO: integrate Italo's spoofer id
        # fixes so that this isn't necessary)
        @spoof_tr_mutex = Mutex.new

        @ping_issuer = Issuers::PingIssuer.new(logger)
        @trace_issuer = Issuers::TraceIssuer.new(logger,@ip_info)
        @spoofed_ping_issuer = Issuers::SpoofedPingIssuer.new(logger)
        @spoofed_trace_issuer = Issuers::SpoofedTraceIssuer.new(logger,@ip_info)
    end

    # ============================================================ #
    #                         Pings                                #
    # ============================================================ #
    
    # We would like to know whether the hops on the 
    # historical foward/reverse/historical reverse paths
    # are pingeable from the source. Send pings, update
    # hop.ping_responsive, and return:
    #   [responsive hops, unresponsive hops]
    def check_reachability!(outage)
        # Always sanity check results by injecting the destination and a
        # stable test IP into the target
        all_hop_sets = [[Hop.new(outage.dst), Hop.new(FailureIsolation::TestPing)],
                         outage.historical_tr, outage.spoofed_tr, outage.historical_revtr]

        # insert all hops on the historical traceroute's hops' reverse paths
        for hop in outage.historical_tr
            all_hop_sets << hop.reverse_path if !hop.reverse_path.nil? and hop.reverse_path.valid?
        end

        handle_ping_request(outage, all_hop_sets)
    end
 
    # we check reachability separately for the revtr hops, since the revtr can take an
    # excrutiatingly long time to execute sometimes
    def check_reachbility_for_revtr!(outage)
        if outage.revtr.valid?
           # TODO: add sanity-check ping targets?
           return handle_ping_request(outage, [outage.revtr]) 
        else
           return [[], []]
        end
    end

    # Are the hops reachable from VPs other than the source?
    def check_pingability_from_other_vps!(connected_vps, non_responsive_hops)
        # there might be multiple hops with the same ip, so we can't have a
        # nice hashmap from ips -> hops
        targets = non_responsive_hops.map { |hop| hop.ip }

        responsive_ips = @ping_issuer.issue(connected_vps, targets)

        non_responsive_hops.each do |hop|
            hop.reachable_from_other_vps = responsive_ips.include? hop.ip
        end

        responsive_ips
    end
    
    # Helper method. Encpasulate raw ips into Hop objects
    def handle_ping_request(outage, all_hop_sets)
        source = outage.src
        all_hop_ips = Set.new
        all_hop_sets.each { |hops| all_hop_ips |= (hops.map { |hop| hop.ip }) }

        responsive_ips = @ping_issuer.issue(source, all_hop_ips.to_a)
        responsive_ips ||= []
        @logger.debug { "Responsive to ping: #{responsive_ips.inspect}" }

        responsive_hops = []
        unresponsive_hops = []
        
        # update hop reachability, and gather lists of responsive/unresponsive hops
        all_hop_sets.each do |hop_set|
            hop_set.each do |hop|
                hop.ping_responsive = responsive_ips.include? hop.ip 
                if hop.ping_responsive
                    responsive_hops << hop
                else
                    unresponsive_hops << hop
                end
            end
        end

        [responsive_hops, unresponsive_hops]
    end

    # ============================================================ #
    #                         Traceroute                           #
    # ============================================================ #

    # Issue a normal traceroute from the source to a list of targets
    # targets is either a single ip, or an array of destination ips
    # return a hash: 
    #   { target -> ForwardPath object }
    # where the ForwardPath objects are empty if the measurement was
    # unsuccessful
    def issue_normal_traceroutes(src, target_or_targets)
        targets = target_or_targets.is_a?(Array) ? target_or_targets : [target_or_targets]
        @trace_issuer.issue(src, targets)
    end

    ## For all reachable hops /beyond/ the suspected failure, issue a
    ## traceroute to them from the source to see how the paths differ
    #def measure_traces_to_pingable_hops(src, suspected_failure, direction, 
    #                                    historical_tr, spoofed_revtr, historical_revtr)
    #    return {} if suspected_failure.nil?
    #
    #    pingable_targets = @failure_analyzer.pingable_hops_beyond_failure(src, suspected_failure, direction, historical_tr)
    #    pingable_targets |= @failure_analyzer.pingable_hops_near_destination(src, historical_tr, spoofed_revtr, historical_revtr)
    #
    #    pingable_targets.map! { |hop| hop.ip }
    #
    #    @logger.debug { "pingable_targets, #{Time.now} #{pingable_targets.inspect}" }
    #
    #    targ2trace = issue_normal_traceroutes(src, pingable_targets)
    #
    #    targ2trace
    #end
    
    # ============================================================ #
    #                         Spoofed Pings                        #
    # ============================================================ #

    # Issue spoofed pings from all receivers towards the destination spoofing
    # as the source. If any of them get through, the reverse path is working
    def issue_pings_towards_srcs!(srcdst2outage)
        srcdst2receivers = srcdst2outage.map_values { |outage| outage.receivers }

        replace_receivers_for_riot!(srcdst2receivers)

        insert_sanity_check_spoofed_pings!(srcdst2receivers)
        
        target2receiver2successful_vps = @spoofed_ping_issuer.issue(srcdst2receivers)

        srcdst2outage.each do |srcdst, outage|
            src, dst = srcdst
            if target2receiver2successful_vps.nil? || target2receiver2successful_vps[dst].nil? ||
                                                      target2receiver2successful_vps[dst][src].nil?
                outage.pings_towards_src = []
            else
                outage.pings_towards_src = target2receiver2successful_vps[dst][src]
            end
        end
            
        log_sanity_check_spoofed_pings(srcdst2receivers, target2receiver2successful_vps, :ping)
    end

    # Helper method. BGP Mux nodes can only spoof to other BGP Mux nodes. Replace all
    # receivers with other BGP Mux nodes.
    def replace_receivers_for_riot!(srcdst2receivers)
        srcdst2receivers.each do |srcdst, receivers| 
            src, dst = srcdst
            if FailureIsolation::PoisonerNames.include? src
                srcdst2receivers[srcdst] = FailureIsolation::PoisonerNames - [src]
            end
        end
    end

    # Helper method. For all spoofed ping requests, inject a ping to
    # c5.millenium.berkeley.edu with receiver toil.cs.washington.edu + all
    # normal receivers. There should always be a response.
    def insert_sanity_check_spoofed_pings!(srcdst2receivers)
        all_receivers = srcdst2receivers.value_set.to_a

        srcdst2receivers.keys.each do |srcdst|
            src = srcdst[0]
            sanity_check_src_dst = [src, FailureIsolation::TestSpoofPing]
            srcdst2receivers[sanity_check_src_dst] = [FailureIsolation::TestSpoofReceiver] + all_receivers.clone
        end
    end
    
    # Helper method. Check all spoofed pings and traceroutes for a response
    # from c5.millennium.berkeley.edu. If there was no response, log a
    # warning.
    def log_sanity_check_spoofed_pings(srcdst2receivers, results, type)
        srcdst2receivers.keys.each do |srcdst|
            src, dst = srcdst
            
            successful = false
            if type == :ping
                next if dst == FailureIsolation::TestSpoofPing
                successful = (results.include?(FailureIsolation::TestSpoofPing) and
                              results[FailureIsolation::TestSpoofPing].include?(src))
            elsif type == :spooftr
                if dst == FailureIsolation::TestSpoofPing
                    successful = (results.include?(srcdst) and not results[srcdst].nil? and
                                  results[srcdst][-1][1].include?(FailureIsolation::TestSpoofPing))
                else
                    successful = results.include?(srcdst) and not results[srcdst].nil?
                end
            end
        
            if successful
                @logger.info { "Successful spoofed #{type} for #{src} #{dst}" }
            else
                @logger.info { "Failed spoofed #{type} for #{src} #{dst}" }
            end
        end
    end

    # ============================================================ #
    #                         Spoofed Traceroutes                  #
    # ============================================================ #
    
    # Issue spoofed traceroutes from all sources to all respective
    # destinations. Mutates outage.spoofed_tr
    def issue_spoofed_traceroutes!(srcdst2outage, dstsrc2outage={})
        @spoof_tr_mutex.synchronize do
            # merging for symmetric outages
            # TODO: add in the other node as the receiver, since we have
            # control over it?
            merged_srcdst2outage = dstsrc2outage.merge(srcdst2outage)
            
            # TODO: send spoofed pings to all receivers?
            srcdst2stillconnected = merged_srcdst2outage.map_values { |outage| outage.receivers }
            replace_receivers_for_riot!(srcdst2stillconnected)

            # TODO: this doesn't just trigger a ping to the test IP -- it triggers a full
            # spoofed traceroute...
            insert_sanity_check_spoofed_pings!(srcdst2stillconnected)

            # Issue spoofed trs all at once to ensure unique spoofer ids
            srcdst2path = @spoofed_trace_issuer.issue(srcdst2stillconnected)
                                                
            srcdst2outage.each do |srcdst, outage|
                outage.spoofed_tr = srcdst2path[srcdst]
            end

            dstsrc2outage.each do |dstsrc, outage|
                outage.dst_spoofed_tr = srcdst2path[srcdst]
            end

            log_sanity_check_spoofed_pings(srcdst2stillconnected, srcdst2sortedttlrtrs, :spooftr)
        end
    end
end
