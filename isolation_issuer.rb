#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << "./"

require 'set'
require 'isolation_utilities'
require 'failure_isolation_consts'
require 'measurement_issuers'

# Isolation system's interface for measurement requests, parsing results, and
# returning encapsulated path objects
class MeasurementRequestor
    def initialize(logger=LoggerLog.new($stderr))
        @logger = logger
        @ping_issuer = Issuers::PingIssuer.new(logger)
        @trace_issuer = Issuers::TraceIssuer.new(logger)
        @spoofed_ping_issuer = Issuers::SpoofedPingIssuer.new(logger)
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

    # TODO: add #check_reachbility_for_revtr!(outage) and
    #       #check_pingability_from_other_vps!(connected_vps, non_responsive_hops)

    # ============================================================ #
    #                         Traceroute                           #
    # ============================================================ #

    # Issue a normal traceroute from the source to a list of targets
    # targets is an array of destination ips
    # return a hash: 
    #   { target -> ForwardPath object }
    # where the ForwardPath objects are empty if the measurement was
    # unsuccessful
    def issue_normal_traceroutes(src, targets)
        @trace_issuer.issue(src, targets)
    end
    
    # ============================================================ #
    #                         Spoofed Pings                        #
    # ============================================================ #

    # Issue spoofed pings from all receivers towards the destination spoofing
    # as the source. If any of them get through, the reverse path is working
    def issue_pings_towards_srcs(srcdst2outage)
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
end
