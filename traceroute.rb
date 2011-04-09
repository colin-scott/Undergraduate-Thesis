module Traceroute
    # dests is an array of destinations
    # return a set of targets that responded
    def Traceroute::sendProbes(hostname, dests, controller)
        $LOG.puts "Traceroute::sendProbe(): source #{hostname}, dests #{dests.inspect}"

        hostname2targets = { hostname => dests }
         
        results,unsuccessful_hosts,privates,blacklisted = controller.traceroute(hostname2targets)

        Traceroute::parse_results results
    end

    private

    # return a set of targets that responded
    def Traceroute::parse_results(results)
        # results is of the form:
        # [[binary, "plgmu4.ite.gmu.edu"]]
        $LOG.puts "Traceroute::parse_results(), raw results: #{results.inspect}"

        dst2ttlhoptuples = {}

        # should only ever iterate once...
        results.each do |p|
            probes = p[0]
            src = p[1]

            trs = []
            begin
                trs = convert_binary_traceroutes(probes)
            rescue TruncatedTraceFileException => e
                $LOG.puts "Truncated trace! #{$!}"
            end

            trs.each do |tr|
                dst = tr[0]
                hops = tr[1]

                ttlhoptuples = []
                hops.each_with_index do |hop, ttl|
                    ttlhoptuples << [ttl+1, hop] 
                end
                
                dst2ttlhoptuples[dst] = ttlhoptuples
            end
        end

        dst2ttlhoptuples
    end
end
