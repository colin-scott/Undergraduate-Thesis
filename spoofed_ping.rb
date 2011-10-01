module SpoofedPing
    # have spoofers spoof pings as vp
    # dests is an array of destinations
    def SpoofedPing::receiveProbes(hostname, dests, spoofers, controller)
        SpoofedPing::format_destinations!(dests)      
        controller.log.debug "SpoofedPing::receiveProbe(): source #{hostname}, dests #{dests.inspect} spoofers are #{spoofers.join(',')}"

        receiver2spoofer2targets = {}
        spoofer2targets = {}
        spoofers.each do |spoofer|
            spoofer2targets[spoofer] = dests.clone
        end 
        receiver2spoofer2targets[hostname] = spoofer2targets

        results,unsuccessful_receivers,privates,blacklisted = controller.spoof_tr(receiver2spoofer2targets, :retry => false)

        SpoofedPing::parse_results results
    end

    # have hostname spoof as receivers towards dests 
    # dests is an array of destinations
    def SpoofedPing::sendProbes(hostname, dests, receivers, controller)
        SpoofedPing::format_destinations!(dests)      
        controller.log.debug "SpoofedPing::sendProbe(): source #{hostname}, dests #{dests.inspect} receivers are #{receivers.join(',')}"

        receiver2spoofer2targets = {}
        spoofer2targets = { hostname => dests }
        receivers.each do |receiver|
            receiver2spoofer2targets[receiver] = spoofer2targets.clone
        end
         
        results,unsuccessful_receivers,privates,blacklisted = controller.spoof_tr(receiver2spoofer2targets, :retry => false)

        SpoofedPing::parse_results results
    end

    def SpoofedPing::receiveBatchProbes(srcdst2spoofers, controller)
        receiver2spoofer2targets = Hash.new { |h,k| h[k] = Hash.new { |h1,k1| h1[k1] = [] } }
        srcdst2spoofers.each do |srcdst, spoofers|
            src, dst = srcdst
            spoofers.each do |spoofer|
                receiver2spoofer2targets[src][spoofer] << dst
            end
        end
        
        id2srcdst = SpoofedPing::format_batch_destinations!(receiver2spoofer2targets) 

        results,unsuccessful_receivers,privates,blacklisted = controller.spoof_tr(receiver2spoofer2targets, :retry => false)

        SpoofedPing::parse_results results
    end

    private

    def SpoofedPing::format_destinations!(dests)
        dests.map! do |dest|
            [dest, 1, 30, 30]
            # dest, id, start ttl, end ttl
        end
    end

    # we don't actually need id2srcdst....
    def SpoofedPing::format_batch_destinations!(receiver2spoofer2targets) 
        id = 0
        id2srcdst = {}
        receiver2spoofer2targets.each do |receiver, spoofer2targets|
            spoofer2targets.each do |spoofer, targets|
                targets.each_with_index do |tr, i|
                    id2srcdst[id] = [spoofer, receiver]
                    targets[i] = [tr, id, 30, 30]
                    id += 1
                end
            end
        end
        
        id2srcdst 
    end

    # takes the raw pingspoof-recv output and returns a nested hash:
    # target -> { receiver => [succesful sender1, succesful sender2...] }
    def SpoofedPing::parse_results(results)
        # do I need to parse differently for the sending/receiving?
        # I could just return a standard hash, and let the callers sort out
        # which direction they care about..

        # DRb can't marshall hashes initialized with a block...
        #target2receiver2succesfulsenders = Hash.new { |hash, key| hash[key] = Hash.new { |h, k| h[k] = [] } }
        target2receiver2succesfulsenders = {}

        results.each do |probes, receiver|
            results, srcs = probes
            results.split("\n").each do |line|
                # 128.208.4.102 1 10 0
                target, id, ttl, src = line.split
                target = target.strip
                src = src.strip
                # XXX
                if !src.eql? "0"
                    target2receiver2succesfulsenders[target] = {} unless target2receiver2succesfulsenders.include? target
                    target2receiver2succesfulsenders[target][receiver] = [] unless target2receiver2succesfulsenders[target].include? receiver 
                    node = ($pl_ip2host.include? src) ? $pl_ip2host[src] : src
                    target2receiver2succesfulsenders[target][receiver] << node
                end # else ttl wasn't high enough
            end
        end

        target2receiver2succesfulsenders
    end
end
