# TODO: re-write this whole thing:
#   - Use hops.rb objects to encapsulate return results rather than hashes
#   - Make it much more readable

module Traceroute
    # dests is an array of destinations
    # return a set of targets that responded
    def Traceroute::sendProbes(hostname, dests, controller)
        controller.log.debug "Traceroute::sendProbe(): source #{hostname}, dests #{dests.inspect}"

        controller.log.warn "Traceroute::sendProbe() Not registered! #{hostname}" unless controller.hosts.include? hostname
        hostname2targets = { hostname => dests }
         
        results,unsuccessful_hosts,privates,blacklisted = controller.traceroute(hostname2targets)

        controller.log.warn "Traceroute::sendProbe() unsuccesful_hosts!: #{unsuccessful_hosts.inspect}" unless unsuccessful_hosts.empty?

        Traceroute::parse_results(results, controller)
    end

    private

    # return a set of targets that responded
    def Traceroute::parse_results(results, controller)
        # results is of the form:
        # [[binary, "plgmu4.ite.gmu.edu"]]
        controller.log.debug "Traceroute::parse_results(), raw results: #{results.inspect}"

        dst2ttlhoptuples = {}

        # should only ever iterate once...
        results.each do |p|
            probes = p[0]
            src = p[1]

            trs = []
            begin
                trs = convert_binary_traceroutes(probes)
            rescue TruncatedTraceFileException => e
                controller.log.debug "Truncated trace! #{$!}"
            end

            trs.each do |tr|
                dst = tr[0].strip
                hops = tr[1]

                ttlhoptuples = []
                hops.each_with_index do |hop, ttl|
                    ttlhoptuples << [ttl+1, hop.strip] 
                end
                
                dst2ttlhoptuples[dst] = ttlhoptuples
            end
        end

        dst2ttlhoptuples
    end
end
