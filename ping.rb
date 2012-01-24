# TODO: re-write this whole thing:
#   - Use hops.rb objects to encapsulate return results rather than string
#   results
#   - Make it much more readable

require 'set'

module Ping
    # dests is an array of destinations
    # return a set of targets that responded
    def Ping::sendProbes(hostname, dests, controller)
        controller.log.debug { "Ping::sendProbe(): source #{hostname}, dests #{dests.inspect}" }

        controller.log.debug { "Ping::sendProbe() Not registered! #{hostname}" } unless controller.hosts.include? hostname
        hostname2targets = { hostname => dests }
         
        results,unsuccessful_hosts,privates,blacklisted = controller.ping(hostname2targets)
        
        controller.log.warn { "Ping::sendProbe() unsuccessful_hosts!: #{unsuccessful_hosts.inspect}" } unless unsuccessful_hosts.empty?

        Ping::parse_results results
    end

    def Ping::all_pairs_ping(srcs,dsts,controller)
        raise "Dests #{dsts.class} isn't an Array!" if !dsts.is_a?(Array)
        hostname2targets = {}
        srcs.each do |src|
            hostname2targets[src] = dsts.clone
        end
         
        results,unsuccessful_hosts,privates,blacklisted = controller.ping(hostname2targets)

        controller.log.warn { "Ping::sendProbe() unsuccessful_hosts!: #{unsuccessful_hosts.inspect}" } unless unsuccessful_hosts.empty?

        return self.parse_all_pairs_results(srcs, results)
    end

    private

    # return a set of targets that responded
    def Ping::parse_results(results)
        # results is of the form:
        # [["74.125.224.48 47 58 69.561996 7743\n128.208.4.244 44 58 78.731003 20416\n", "plgmu4.ite.gmu.edu"]]
        # controller.log.info { "Ping::parse_results(), raw results: #{results.inspect}" }

        responsive_targets = Set.new
        
        self.split_binary(results) do |target, ipid, fifteight, rtt, something, sender|
            responsive_targets.add target.strip
        end

        responsive_targets
    end

    def Ping::split_binary(results)
       results.each do |probes, sender|
            data = probes
            data.split("\n").each do |line|
                # 74.125.224.48 47 58 69.561996 7743
                target, ipid, fiftyeight, rtt, something = line.split
                yield target, ipid, fiftyeight, rtt, something, sender
            end
        end
    end

    def Ping::parse_all_pairs_results(srcs, results)
        # results is of the form:
        # [["74.125.224.48 47 58 69.561996 7743\n128.208.4.244 44 58 78.731003 20416\n", "plgmu4.ite.gmu.edu"]]
        # controller.log.info { "Ping::parse_results(), raw results: #{results.inspect}" }

        src2responsive = {}
        srcs.each { |src| src2responsive[src] = [] }

        self.split_binary(results) do |target, ipid, fifteight, rtt, something, sender|
            src2responsive[sender] << target
        end

        return src2responsive
    end
end
