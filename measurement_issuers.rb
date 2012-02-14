#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << "./"

require 'set'
require 'isolation_utilities'
require 'failure_isolation_consts'

# Issues RPCs to the controller
module Issuers
    # Helper method. Are the vps registered with the controller?
    # If not, (warn|raise).
    def self.check_registration(caller_name, vps, logger)
        ProbeController.issue_to_controller do |controller|
            hosts = controller.hosts
            logger.debug "check_registration(): hosts #{hosts.inspect}"
            # TODO: raise exception instead
            vps.each do |source_hostname|
                logger.warn { "#{caller_name}: Not registered! #{source_hostname}" } unless hosts.include? source_hostname
            end
        end
    end

    # Helper method. Sanity check that all sources are registered, feed
    # controller_input to the controller, warn about unsuccessful hosts,
    # and return the results
    #
    # TODO: controller_method should be the first arg
    def self.issue(vps, controller_input, controller_method, logger)
        caller_name = caller[1]
        logger.debug { "#{caller_name}: vps #{vps.inspect} input #{controller_input.inspect}" }

        Issuers.check_registration(caller_name, vps, logger)

        results,unsuccessful_hosts,privates,blacklisted = [[]] * 4

        ProbeController.issue_to_controller do |controller|
            results,unsuccessful_hosts,privates,blacklisted = controller.send(controller_method, controller_input)
        end

        if not unsuccessful_hosts.empty?
            logger.warn { "#{caller_name} unsuccessful_hosts!: #{unsuccessful_hosts.inspect}" } 
        end
        
        return results
    end

    class PingIssuer
        def initialize(logger=LoggerLog.new($stderr))
            @logger = logger
            @parser = Parsers::PingParser.new(logger)
        end

        # targets is an array of destination ips
        # return a set of target ips that responded
        def issue(source_hostname, targets)
            hostname2targets = { source_hostname => targets }
            controller_results = Issuers.issue([source_hostname],hostname2targets,:ping,@logger)
            return @parser.parse(controller_results)
        end
    end

    class TraceIssuer 
        def initialize(logger=LoggerLog.new($stderr),ip_info=IpInfo.new)
            @logger = logger
            @parser = Parsers::TraceParser.new(logger,ip_info)
        end

        # dests is an array of destination ips
        # return a hash: 
        #   { dest ip -> ForwardPath object }
        # where the ForwardPath objects are empty if the measurement was
        # unsuccessful
        #
        # TODO: take multiple sources as a parameter instead of a single source?
        def issue(source_hostname, dests)
            hostname2targets = { source_hostname => dests }
            results = Issuers.issue([source_hostname],hostname2targets,:traceroute,@logger) 
            return @parser.parse(results, source_hostname, dests)
        end
    end

    # Helper method. Convert input to the format that the controller expects.
    # start_ttl, end_ttl are to allow this method to be shared by both
    # spoofed tr and spoofed ping.
    #
    # returns:
    #    [all_vps, spooferid2srcdst, receiver2spoofer2targets]
    def self.canonocalize_spoof_input(srcdst2receivers, start_ttl, end_ttl)
        all_vps = Set.new

        # Need to convert to the format that the controller expects
        receiver2spoofer2targets = {}
        srcdst2receivers.each do |srcdst,receivers|
            spoofer, target = srcdst
            all_vps.add spoofer

            receivers.each do |receiver|
                all_vps.add receiver

                # DRb can't marshal Hashes intitialized with blocks...
                receiver2spoofer2targets[receiver] ||= {}
                receiver2spoofer2targets[receiver][spoofer] ||= []
                receiver2spoofer2targets[receiver][spoofer] << target
            end
        end

        id2srcdst = self.allocate_spoofer_ids!(receiver2spoofer2targets, start_ttl, end_ttl)

        [all_vps,id2srcdst,receiver2spoofer2targets]
    end

    # Helper method. Assign a unique spoofer id to each (src,dst) pair.
    # Mutate receiver2spoofer2targets such that the targets include the
    # spoofer id, the start ttl, and the end ttl.
    # Return a hash: { spoofer id -> [src,dst] }
    def self.allocate_spoofer_ids!(receiver2spoofer2targets, start_ttl, end_ttl)
        id = 0
        id2srcdst = {}

        receiver2spoofer2targets.each do |receiver, spoofer2targets|
            spoofer2targets.each do |spoofer, targets|
                # memory leak???
                max_iterations = targets.size 
                curr_iteration = 0
                targets.each_with_index do |tr, i|
                    curr_iteration += 1
                    raise "found the memory leak #{caller}!!!" if curr_iteration > max_iterations
                    id2srcdst[id] = [spoofer, tr]
                    targets[i] = [tr, id, start_ttl, end_ttl]
                    id += 1
                end
            end
        end
        
        id2srcdst
    end

    class SpoofedPingIssuer
        def initialize(logger=LoggerLog.new($stderr))
            @logger = logger
            @parser = Parsers::SpoofedPingParser.new(logger)
        end

        # spoofers and receivers are arrays of VP hostnames
        # targets is an array of destination ips
        # returns a nested hash:
        #   target -> { receiver => [succesful sender1, succesful sender2...] }
        def issue(srcdst2receivers)
            # We insert a start and end ttl of 30, then piggyback on
            # controller.spoof_tr
            all_vps, id2srcdst, receiver2spoofer2targets = Issuers.canonocalize_spoof_input(srcdst2receivers, 40, 40)
            controller_results = Issuers.issue(all_vps,receiver2spoofer2targets,:spoof_tr,@logger)
            return @parser.parse(controller_results)
        end
    end

    class SpoofedTraceIssuer
        def initialize(logger=LoggerLog.new($stderr),ip_info=IpInfo.new)
            @logger = logger
            @parser = Parsers::SpoofedTraceParser.new(logger, ip_info)
        end

        # dests is an array of destination ips
        # return a hash: 
        #   { dest ip -> ForwardPath object }
        # where the ForwardPath objects are empty if the measurement was
        # unsuccessful
        #
        # TODO: take multiple sources as a parameter instead of a single source?
        def issue(srcdst2receivers)
            all_vps, id2srcdst, receiver2spoofer2targets = Issuers.canonocalize_spoof_input(srcdst2receivers, 0, 40)
            controller_results = Issuers.issue(all_vps,receiver2spoofer2targets,:spoof_tr,@logger)
            return @parser.parse(controller_results, id2srcdst)
        end
    end
end

# Parses raw measurment results from the controller
module Parsers
    class PingParser
        def initialize(logger=LoggerLog.new($stderr))
            @logger = logger
        end

        # return a set of ips that responded
        def parse(results)
            # results is of the form:
            # [["74.125.224.48 47 58 69.561996 7743\n128.208.4.244 44 58 78.731003 20416\n", "plgmu4.ite.gmu.edu"]]
            # @logger.info { "Ping::parse_results(), raw results: #{results.inspect}" }

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

    class SpoofedPingParser
        def initialize(logger=LoggerLog.new($stderr))
            @logger = logger
        end

        # takes the raw pingspoof-recv output and returns a nested hash:
        # target -> { receiver => [succesful sender hostname 1, succesful sender hostname 2...] }
        def parse(results)
            # results is of the form:
            #   [[probes,receiver],...]
            target2receiver2succesfulsenders = Hash.new { |hash, key| hash[key] = Hash.new { |h, k| h[k] = [] } }

            results.each do |probes, receiver|
                # probes is of the form:
                #   [ascii output, sources]
                # sources is not usually useful, since not enough of the original IMCP
                # header is reflected in time-exceeded messages. I believe
                # sources is inferred from the ICMPID field, where we store
                # the spoofer id
                
                # TODO: how often does fragmentation occur on the Internet?
                # since we're screwing with the IPID field, we might get wonky
                # results in the case of fragmentation...
                
                ascii_results, sources = probes
                ascii_results.split("\n").each do |line|
                    # 128.208.4.102 1 10 0
                    target, id, ttl, src = line.split
                    target = target.strip
                    src = src.strip

                    # If it was a time-exceed message, the src will be set to "0"
                    # Else, the ip address of the source will be taken
                    # from the payload of the ping reply. 
                    if !src.eql? "0"
                        # TODO: use db.ip2host
                        node = ($pl_ip2host.include? src) ? $pl_ip2host[src] : src
                        target2receiver2succesfulsenders[target][receiver] << node
                    end # we ignore time-exceeded messages
                end
            end

            target2receiver2succesfulsenders
        end
    end

    class TraceParser
        def initialize(logger=LoggerLog.new($stderr),ip_info=IpInfo.new)
            @logger = logger
            @ip_info = ip_info
        end

        # return a hash: 
        #   { dest ip -> ForwardPath object }
        # where the ForwardPath objects are empty if the measurement was
        # unsuccessful
        def parse(results, src, dsts)
            # results is of the form:
            # [[binary, "plgmu4.ite.gmu.edu"]]
            
            # Initialize hash from an array of [key,value] pairs
            dst2path = Hash[ dsts.map { |dst| [dst, ForwardPath.new(src, dst)] } ]

            raise "Only expected a single source (#{results.map { |t| t[1] }.inspect})" if results.size > 1

            probes, vp = results.first

            raise "Results from #{vp} != expected source #{src}" if vp != src

            trs = []
            begin
                # returns a list of trs, where tr is
                # [dst ip, [ip1,ip2,ip3..,ipn]]
                trs = convert_binary_traceroutes(probes)
            rescue TruncatedTraceFileException => e
                # TODO: perhaps I should force the caller to catch these?
                # would allow them to do their own empty trace accounting
                @logger.warn { "Truncated trace! #{$!}" }
            end

            trs.each do |tr|
                dst, ascii_hops = tr
                dst = dst.strip

                raise "trace to destination #{dst} not requested!" unless dsts.include? dst

                hops = []
                ascii_hops.each_with_index do |hop, ttl|
                    hops << ForwardHop.new([ttl+1, hop.strip], @ip_info)
                end
                
                dst2path[dst] = ForwardPath.new(src, dst, hops)
            end

            dst2path
        end
    end

    class SpoofedTraceParser
        def initialize(logger=LoggerLog.new($stderr),ip_info=IpInfo.new)
            @logger = logger
            @ip_info = ip_info
        end

        # return a hash: { [src,dst] -> ForwardPath object }
        def parse(results, id2srcdst)
            @logger.debug { "parse_path(), results: #{results.inspect}" }
            @logger.debug { "parse_path(), id2srcdst: #{id2srcdst.inspect}" }

            # Intermediate state while we're gathering (out-of-order) hops
            # Initialize with a list of (key,value) pairs. 
            srcdst2hops = Hash[ id2srcdst.values.map { |srcdst| [srcdst, []] } ]

            # results is [[probes, reciever], [probes, receiever], ...] 
            results.each do |probes, receiver| 
                # probes is
                #   [ascii data, [src1,...]]
                # sources is not usually useful, since not enough of the original IMCP
                # header is reflected in time-exceeded messages. I believe
                # sources is inferred from the ICMPID field, where we store
                # the spoofer id
                data, sources = probes
                data.split("\n").each do |line|
                    # We associate a spoofer id with each (src,dst) pair
                    # 128.208.4.102 1 10 0
                    # TODO: what does lastHop stand for?
                    hop_ip, id, ttl, lastHop = line.split
                    id = id.to_i
                    ttl = ttl.to_i
                    srcdst = id2srcdst[id]
                    next if ttl == 0 # get rid of extraneous hole punches
                    if ttl.nil? # not sure why this would ever happen
                        @logger.warn { "ttl was nil for spoofed tr #{line}" }
                        next
                    end
                    if srcdst.nil? # not sure why this would ever happen
                        @logger.warn { "spoofer id was nil for spoofed tr #{line}" }
                        next
                    end
                    srcdst2hops[srcdst] << SpoofedForwardHop.new(hop_ip, ttl, @ip_info)
                end
            end

            srcdst2path = {}

            srcdst2hops.each do |srcdst, hops|
                src, dst = srcdst
                # Note that sorting ttls and removing redundant hops is
                # performed in the ForwardPath initializer
                srcdst2path[srcdst] = ForwardPath.new(src, dst, hops)
            end

            srcdst2path
        end
    end
end

