#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << "./"

require 'set'
require 'isolation_utilities'

# Issues RPCs to the controller
module Issuer
    class PingIssuer
        def initialize(logger)
            @logger = logger
            @parser = Parsers::PingParser.new(logger)
        end

        # targets is an array of destination ips
        # return a set of target ips that responded
        def issue(source_hostname, targets)
            @logger.debug { "issue_ping_request(): source #{hostname}, dests #{dests.inspect}" }

            ProbeController.issue_to_controller do |controller|
                hosts = controller.hosts
                # TODO: raise exception instead
                @logger.warn { "issue_ping_request(): Not registered! #{hostname}" } unless hosts.include? source_hostname
            end
            
            hostname2targets = { source_hostname => dests }

            ProbeController.issue_to_controller do |controller|
                results,unsuccessful_hosts,privates,blacklisted = controller.ping(hostname2targets)
            end

            if not unsuccessful_hosts.empty?
                @logger.warn { "issue_ping_request(), unsuccessful_hosts!: #{unsuccessful_hosts.inspect}" } 
            end
            
            return @parser.parse(results)
        end
    end
end

# Parses raw measurment results from the controller
module Parsers
    class PingParser
        def initialize(logger)
            @logger = logger
        end

        # return a set of ips that responded
        def parse(results)
            # results is of the form:
            # [["74.125.224.48 47 58 69.561996 7743\n128.208.4.244 44 58 78.731003 20416\n", "plgmu4.ite.gmu.edu"]]
            # controller.log.info { "Ping::parse_results(), raw results: #{results.inspect}" }

            responsive_ips = Set.new
            
            split_raw_results(results) do |target, ipid, fiftyeight, rtt, something, sender|
                # We throw away information about the sender for now
                responsive_ips.add target.strip
            end

            responsive_ips
        end

        # helper method. Takes a block with the following signature:
        #   |target, ipid, fiftyeight, rtt, something, sender|
        def split_raw_results(results)
           results.each do |probes, sender|
                data = probes
                data.split("\n").each do |line|
                    # 74.125.224.48 47 58 69.561996 7743
                    target, ipid, fiftyeight, rtt, something = line.split
                    yield target, ipid, fiftyeight, rtt, something, sender
                end
            end
        end
    end
end

# Top-level class for issuing measurement requests, parsing results, and
# returning encapsulated path objects
class MeasurementRequestor
    def initialize(logger=LoggerLog.new($stderr))
        @logger = logger
        @ping_issuer = Issuer::PingIssuer.new(logger)
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
end

