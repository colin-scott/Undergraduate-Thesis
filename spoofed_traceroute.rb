# NOTE!
# I suspect that the memory leak might be in this file...

require 'set'

module SpoofedTR
    # for backwards compatibility...
    # TODO: modify spoofed_traceroute_client.rb to use srcdst2ttl2rtrs rather
    # than dst2ttl2rtrs so that I can get rid of the ugly redundancy
    def SpoofedTR::sendProbes(hostname, dests, receivers, controller)
        # we associate an id with each destination, so that we can distinguish
        # probes later on
        id2dest = SpoofedTR::allocate_ids(dests)

        controller.log.debug "SpoofedTR::sendProbes(), source #{hostname}, dests #{dests} receivers are #{receivers.join(',')}"
        receiver2spoofer2targets = {}
        spoofer2targets = { hostname => dests }
        receivers.each { |reciever| receiver2spoofer2targets[reciever] = spoofer2targets.clone }
        controller.log.debug "SpoofedTR::sendProbes(), receiver2spoofer2targets: #{receiver2spoofer2targets.inspect}"
        results,unsuccessful_receivers,privates,blacklisted = controller.spoof_tr(receiver2spoofer2targets)

        controller.log.debug "SpoofedTR::sendProbes(#{hostname} #{dests.inspect}), results,unsuccessful_receivers,privates,blacklisted"
        controller.log.debug "#{results.inspect},#{unsuccessful_receivers.inspect},#{privates.inspect},#{blacklisted.inspect}"
        SpoofedTR::parse_path(results, id2dest, controller)
    end

    def SpoofedTR::sendBatchProbes(srcdst2receivers, controller)
        receiver2spoofer2targets = {}
        srcdst2receivers.each do |srcdst, receivers|
            src, dst = srcdst
            receivers.each do |receiver|
                receiver2spoofer2targets[receiver] = {} unless receiver2spoofer2targets.include? receiver
                receiver2spoofer2targets[receiver][src] = [] unless receiver2spoofer2targets[receiver].include? src
                receiver2spoofer2targets[receiver][src] << dst
            end
        end

        id2srcdst = SpoofedTR::allocate_batch_ids(receiver2spoofer2targets)

        results,unsuccessful_receivers,privates,blacklisted = controller.spoof_tr(receiver2spoofer2targets)
        SpoofedTR::parse_path(results, id2srcdst, controller) # this actually works with either id2srcdst or id2dst...
    end

    private

    # XXX For backwards compatibility
    def SpoofedTR::allocate_ids(dests)
        id = 0
        id2dest = {}

        # infinite loop?????????????? this might be the point where strings
        # are allocated infinitely
        max_iterations = dests.size
        curr_iteration = 0

        dests.each_with_index do |tr, i|
            curr_iteration += 1
            raise "found the memory leak!!!!" if curr_iteration > max_iterations

            if tr.is_a?(Array)
                id2dest[id] = tr[0]
                tr.insert(1, id)
            else # just a string representing the destination
                id2dest[id] = tr
                dests[i] = [tr, id]
            end

            id += 1
        end

        id2dest
    end

    def SpoofedTR::allocate_batch_ids(receiver2spoofer2targets)
        id = 0
        id2srcdst = {}

        receiver2spoofer2targets.each do |receiver, spoofer2targets|
            spoofer2targets.each do |spoofer, targets|
                # memory leak???
                max_iterations = targets.size 
                curr_iteration = 0
                targets.each_with_index do |tr, i|
                    curr_iteration += 1
                    raise "found the memory leak!!!" if curr_iteration > max_iterations
                    id2srcdst[id] = [spoofer, tr]
                    targets[i] = [tr, id]
                    id += 1
                end
            end
        end
        
        id2srcdst
    end

    # results is [[probes, reciever], [probes, receiever], ...] 
    def SpoofedTR::parse_path(results, id2dest, controller)
        controller.log.debug "parse_path(), results #{results.inspect}"

        # DRb can't unmarshall hashes initialized with blocks...
        dest2ttl2rtrs = {} # or srcdst2ttl2rtrs....

        # XXX doubtful... but....
        raise "found the memory leak!" if results.size > 10000

        results.each do |probes, receiver| 
            # We associate a spoofer id with each destination
            data, srcs = probes
            data.split("\n").each do |line|
                # 128.208.4.102 1 10 0
                target, id, ttl, lastHop = line.split
                id = id.to_i
                ttl = ttl.to_i
                dest = id2dest[id]
                dest2ttl2rtrs[dest] = {} unless dest2ttl2rtrs.include? dest
                dest2ttl2rtrs[dest][ttl] = Set.new unless dest2ttl2rtrs[dest].include? ttl
                dest2ttl2rtrs[dest][ttl].add target
            end
        end

        controller.log.debug "parse_path(), id2dest #{id2dest.inspect}"
        controller.log.debug "parse_path(), dest2ttl2rtrs before merge #{dest2ttl2rtrs.inspect}"

        # why would dest ever be nil?  id2dest didn't include the id...
        # We saw one case where one of the hops was attached to a nil key, not
        # the target
        if id2dest.size == 1 and dest2ttl2rtrs.size > 1 and dest2ttl2rtrs.include?(intended_target = id2dest.values[0])
            # memory leak???
            # XXX
            max_iterations = dest2ttl2rtrs.size
            curr_iteration = 0

            dest2ttl2rtrs.each do |dest, ttl2rtrs|
                curr_iteration += 1
                raise "found the memory leak!" if curr_iteration > max_iterations

                next if dest.eql? intended_target

                # BAHHH
                inner_iteration = 0 

                dest2ttl2rtrs[dest].each do |ttl, rtrs|
                    inner_iteration += 1
                    raise "found the memory leak!" if inner_iteration > max_iterations

                    dest2ttl2rtrs[intended_target][ttl] = Set.new unless dest2ttl2rtrs[intended_target].include? ttl
                    dest2ttl2rtrs[intended_target][ttl] |= rtrs

                end
            end
        end

        controller.log.debug "parse_path(), dest2ttl2rtrs after merge #{dest2ttl2rtrs.inspect}"
        
        dest2sortedttlrtrs = {}

        # XXX
        max_iterations = dest2ttl2rtrs.size
        curr_iteration = 0

        dest2ttl2rtrs.keys.each do |dest|
            curr_iteration += 1 
            raise "found the memory leak!" if curr_iteration > max_iterations

            # get rid of extraneous hole punches
            dest2ttl2rtrs[dest].delete(0)

            # turn sets into arrays
            dest2ttl2rtrs[dest].each do |ttl, rtrs|
               dest2ttl2rtrs[dest][ttl] = rtrs.to_a.map { |h| h.strip }
            end

            # convert into [ttl, rtrs] pairs
            sortedttlrtrs = dest2ttl2rtrs[dest].to_a.sort_by { |ttlrtrs| ttlrtrs[0] }
            # get rid of redundant destination ttls at the end
            #controller.log.debug "parse_path(#{dest}): sortedttlrtrs: #{sortedttlrtrs.inspect}"
            target = dest.is_a?(Array) ? dest[1] : dest   # sometimes dest is really srcdst.... XXX
            while sortedttlrtrs.size > 1 and sortedttlrtrs[-1][1].include? target and sortedttlrtrs[-2][1].include? target 
                sortedttlrtrs = sortedttlrtrs[0..-2]
            end

            # NOW!!! IF there were a bunch of zeroes before the last hop, but
            # the last hop was responsive, we likely have a problem with our
            # tools (riot). So get rid of it!
            if sortedttlrtrs.size > 2 and (sortedttlrtrs[-1][0].to_i - sortedttlrtrs[-2][0].to_i) > 4
                sortedttlrtrs = sortedttlrtrs[0..-2]
            end

            # 0.0.0.0's
            SpoofedTR::fill_in_zeroes!(sortedttlrtrs)
            
            dest2sortedttlrtrs[dest] = sortedttlrtrs
        end

        controller.log.debug "parse_path(), dest2sortedttlrtrs converting to arrays #{dest2sortedttlrtrs.inspect}"

        dest2sortedttlrtrs
   end

   # wow, this is a convoluted piece of code...
   # fill in gaps with "0.0.0.0"
   def self.fill_in_zeroes!(sortedttlrtrs)
     return if sortedttlrtrs.empty?
     #raise "insensible input! max ttl shouldn't be greater than 45...\n#{sortedttlrtrs.inspect}" if sortedttlrtrs[-1][0]-1 > 45 #XXX
     return if sortedttlrtrs[-1][0]-1 > 45 # packet corruption perhaps...
     0.upto(sortedttlrtrs[-1][0]-1) do |i|
         sortedttlrtrs.insert(i, [i+1, ["0.0.0.0"]]) unless sortedttlrtrs[i][0] == i+1
     end
   end
end
