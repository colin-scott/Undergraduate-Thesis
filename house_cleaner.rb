#!/homes/network/revtr/ruby/bin/ruby

require 'failure_isolation_consts'
require 'set'
require 'mysql'
require 'mail'
require 'socket'
require 'utilities'
require 'db_interface'

# Invariant:
#    - Never monitor a site that already has a monitoring nodes (only the rest
#           of the spoofer sites)

class HouseCleaner
    def initialize(logger=LoggerLog.new($stderr), db = DatabaseInterface.new)
        @logger = logger
        @db = db
    end

    # returns a tuple
    #   First, sorted pop #s by degree
    #   Second, pop2corertrs
    #     { pop -> [corertr1, corertr2...] }
    #   Third, pop2edgertrs
    #     { pop -> [edgertr1, edgertr2...] }
    def generate_top_pops(regenerate=true)
        @logger.debug "generating top pops..."
        system "#{FailureIsolation::TopPoPsScripts} #{FailureIsolation::NumTopPoPs}" if regenerate

        sorted_pops = IO.read(FailureIsolation::TopN).split("\n").map { |line| line.split[0].to_sym } 
        pops_set = Set.new(sorted_pops)

        # generate pop, core mappings
        pop2corertrs = Hash.new { |h,k| h[k] = [] }
        FailureIsolation.IPToPoPMapping.each do |ip, pop|
            pop2corertrs[pop] << ip if pops_set.include? pop and !FailureIsolation.TargetBlacklist.include? ip
        end

        @logger.debug "core routers generated"

        # generate pop, edge mappings
        popsrcdsts = IO.read(FailureIsolation::SourceDests).split("\n")\
                        .map { |line| line.split }.map { |triple| [triple[0].to_sym, triple[1,2]] }
        # TODO: filter out core routers?
                        
        # only grab edge routers seen from at least one of our VPs
        current_vps = Set.new(IO.read(FailureIsolation::CurrentNodesPath).split("\n")\
                              .map { |node| @db.hostname2ip[node] })

        pop2edgertrs = Hash.new { |h,k| h[k] = [] }
        popsrcdsts.each do |popsrcdst| 
            pop, srcdst = popsrcdst
            next unless pops_set.include? pop # should be included...
            src, dst = srcdst
            next unless current_vps.include? src
            pop2edgertrs[pop] << dst unless FailureIsolation.TargetBlacklist.include? dst
        end

        @logger.debug "edge routers generated"

        currently_used_pops = Set.new(FailureIsolation.HarshaPoPs.map { |ip| FailureIsolation.IPToPoPMapping[ip] })

        sorted_replacement_pops = sorted_pops.find_all { |pop| !currently_used_pops.include? pop }

        [sorted_replacement_pops, pop2corertrs, pop2edgertrs]
    end

    def refill_pops(pop2unresponsivetargets, num_rtrs_per_pop, pop2replacements, sorted_replacement_pops)
        chosen_replacements = []
        pop2unresponsivetargets.each do |pop, unresponsivetargets|
            if pop == PoP::Unknown
                next
                # XXX
            end
            
            num_needed_replacements = unresponsive.targets.size
            if num_needed_replacements < num_rtrs_per_pop && pop2replacements[pop].size > num_needed_replacements
                # for those pops that are partially gone,
                # add targets from new generation
                num_needed_replacements.times { chosen_replacements << pop2replacements[pop].shift }
            else
                # for those pops that are completely gone,
                # pick a new top pop, and add targets from that
                replacement_pop = sorted_replacement_pops.shift 

                while pop2replacements[replacement_pop].size < num_needed_replacements
                    replacement_pop = sorted_replacement_pops.shift 
                end
                
                num_needed_replacements.times { chosen_replacements << pop2replacements[pop].shift }
            end
        end
        chosen_replacements
    end

    def find_substitutes_for_unresponsive_targets()
        dataset2substitute_targets = Hash.new { |h,k| h[k] = Set.new }

        bad_hops, possibly_bad_hops, bad_targets, possibly_bad_targets = @db.check_target_probing_status(FailureIsolation.TargetSet)

        # TODO: do something with bad_hops
        @logger.debug "bad_hops: #{bad_hops}"
        @logger.debug "bad_targets: #{bad_targets}"
        
        dataset2unresponsive_targets = Hash.new { |h,k| h[k] = [] }

        bad_targets.each do |target|
            @logger.debug ". #{target} identifying"
            # identify which dataset it came from
            dataset = FailureIsolation.get_dataset(target) 
            if dataset == DataSets::Unknown
                @logger.warn "unknown target #{target}" 
                next
            end

            dataset2unresponsive_targets[dataset] << target
        end

        @logger.debug "dataset2unresponsive_targets: #{dataset2unresponsive_targets.inspect}"

        #find_subs_for_harsha_pops(dataset2unresponsive_targets, dataset2substitute_targets)

        # cloudfront is static

        find_subs_for_spoofers(dataset2unresponsive_targets, dataset2substitute_targets)

        [dataset2substitute_targets, dataset2unresponsive_targets, possibly_bad_targets, bad_hops, possibly_bad_hops]
    end

    def find_subs_for_harsha_pops(dataset2unresponsive_targets, dataset2substitute_targets)
        sorted_replacement_pops, pop2corertrs, pop2edgertrs = generate_top_pops

        # (see utilities.rb for .categorize())
        core_pop2unresponsivetargets = dataset2unresponsive_targets[DataSets::HarshaPoPs]\
                                        .categorize(FailureIsolation.IPToPoPMapping, DataSets::Unknown)

        dataset2substitute_targets[DataSets::HarshaPoPs] = refill_pops(core_pop2unresponsivetargets,
                                                                             FailureIsolation::CoreRtrsPerPoP,
                                                                             pop2corertrs, sorted_replacement_pops)
        @logger.debug "Harsha PoPs substituted"
        
        # (see utilities.rb for .categorize())
        edge_pop2unresponsivetargets = dataset2unresponsive_targets[DataSets::BeyondHarshaPoPs].categorize(FailureIsolation.IPToPoPMapping, DataSets::Unknown)

        dataset2substitute_targets[DataSets::BeyondHarshaPoPs] = refill_pops(edge_pop2unresponsivetargets,
                                                                                   FailureIsolation::EdgeRtrsPerPoP,
                                                                                   pop2edgertrs, sorted_replacement_pops)

        @logger.debug "Edge PoPs substituted"
    end

    def find_subs_for_spoofers(dataset2unresponsive_targets, dataset2substitute_targets)
        # should only be probing one per site
        unresponsive_spoofers = dataset2unresponsive_targets[DataSets::SpooferTargets] 
        site2chosen_node = choose_one_spoofer_target_per_site(unresponsive_spoofers)
        update_pl_pl_meta_data(site2chosen_node)

        dataset2substitute_targets[DataSets::SpooferTargets] = site2chosen_node.values
    end

    # For Ethan's PL-PL traceroutes -- <hostname> <ip> <site>
    def update_pl_pl_meta_data(site2chosen_node)
        # We include both monitoring nodes and spoofer targets
        site2node_ip_tuple = {}
        FailureIsolation.CurrentNodes.each do |spoofer|
            site2node_ip_tuple[FailureIsolation.Host2Site[spoofer]] = [spoofer, @db.hostname2ip[spoofer]]
        end

        site2chosen_node.each do |site, chosen_node|
            site2node_ip_tuple[site] = [chosen_node, @db.hostname2ip[chosen_node]]
        end

        output = File.open(FailureIsolation::SpooferTargetsMetaDataPath, "w")
        site2node_ip_tuple.each do |site, node_ip|
            output.puts "#{node_ip.join ' '} #{site}"
        end
        output.close
    end
     
    def choose_one_spoofer_target_per_site(bad_targets_ips)
        # prefer spoofers that are already chosen
        # for all sites that don't have a spoofer target or a monitor, add one that hasn't been
        # blacklisted
        site2chosen_node = {}

        all_sites = FailureIsolation.Site2Hosts.keys

        # all controllable
        all_controllable = @db.controllable_isolation_vantage_points.values
        site2controllable_nodes = Hash.new { |h,k| h[k] = [] }
        all_controllable.each do |host|
            site2controllable_nodes[FailureIsolation.Host2Site[host]] << host
        end

        # currently probed
        site2current_spoofer = {}
        FailureIsolation.SpooferTargets.each do |spoofer_ip|
            spoofer = @db.ip2hostname[spoofer_ip]
            site2current_spoofer[FailureIsolation.Host2Site[spoofer]] = spoofer
        end

        # already have a monitoring node
        site2monitoring_node = {}
        FailureIsolation.CurrentNodes.each do |spoofer|
            site2monitoring_node[FailureIsolation.Host2Site[spoofer]] = spoofer
        end

        all_sites.each do |site|
            if site2monitoring_node.include? site
                next
            end

            if site2current_spoofer.include? site and !FailureIsolation.TargetBlacklist.include? site2current_spoofer[site] and 
                         !bad_targets_ips.include? @db.hostname2ip[site2current_spoofer[site]]
                site2chosen_node[site] = site2current_spoofer[site]
                next
            end

            site2controllable_nodes[site].delete_if { |hop| FailureIsolation.TargetBlacklist.include? host or \
                                                         bad_targets_ips.include? @db.hostname2ip[host] }
            if !site2controllable_nodes[site].empty?
                site2chosen_node[site] = site2controllable_nodes[site].shift
            end
        end

        site2chosen_node
    end

    def update_data_set(dataset, substitute_targets, bad_targets)
        path = DataSets::ToPath(dataset)

        old_targets = Set.new IO.read(path).split("\n")
        new_targets = (old_targets - bad_targets.to_set + substitute_targets.to_set)
        File.open(path, "w") { |f| f.puts new_targets.to_a.join "\n" }
    end

    # TODO: separate this into two methods: remove, and substitute
    # precondition: bad_targets are a subset of the current datasets
    def swap_out_unresponsive_targets(dataset2unresponsive_targets, dataset2substitute_targets)
        bad_targets = dataset2unresponsive_targets.is_a?(Hash) ? \
                       dataset2unresponsive_targets.value_set : \
                       dataset2unresponsive_targets 

        @logger.debug "swapping out unresponsive targets: #{bad_targets}"

        update_target_blacklist(bad_targets.to_set | FailureIsolation.TargetBlacklist)
        @logger.debug "blacklist updated"

        dataset2substitute_targets.each do |dataset, substitute_targets|
            update_data_set(dataset, substitute_targets, bad_targets)
        end

        FailureIsolation.ReadInDataSets()

        @logger.debug "target lists updated"
    end

    # TODO: grab subtitute nodes from the database, not the static file
    # TODO: make the blacklist site-specific, not host-specific
    def swap_out_faulty_nodes(faulty_nodes)
        @logger.debug "swapping out faulty nodes: #{faulty_nodes}"

        all_nodes = Set.new(@db.controllable_isolation_vantage_points.keys)
        blacklist = FailureIsolation.NodeBlacklist
        current_nodes = FailureIsolation.CurrentNodes
        current_sites = Set.new(current_nodes.map { |node| FailureIsolation.Node2Site[node] })
        available_nodes = (all_nodes - blacklist - current_nodes).to_a.sort_by { |node| rand }
        
        faulty_nodes.each do |broken_vp|
            if !current_nodes.include? broken_vp
                @logger.warn "#{broken_vp} not in current node set..."
                next 
            end
        
            current_nodes.delete broken_vp
            blacklist.add broken_vp
            system "echo #{broken_vp} > #{FailureIsolation::NodeToRemovePath} && pkill -SIGUSR2 -f run_failure_isolation.rb"
        end

        
        
        while current_nodes.size < FailureIsolation::NumActiveNodes
            raise "No more nodes left to swap!" if available_nodes.empty?
            new_vp = available_nodes.shift
            new_vp_site = FailureIsolation.Node2Site[new_vp]
            next if current_sites.include? new_vp_site
            @logger.debug "choosing: #{new_vp}"
            current_nodes.add new_vp
            current_sites.add new_vp_site
        end

        update_current_nodes(current_nodes)
        update_blacklist(blacklist)
        FailureIsolation.ReadInNodeSets()

        system "rm #{FailureIsolation::PingStatePath}/*"
    end

    def add_nodes(nodes)
        current_nodes = Set.new(IO.read(FailureIsolation::CurrentNodesPath).split("\n"))
        current_nodes |= nodes
        
        update_current_nodes(current_nodes)
    end

    def update_current_nodes(current_nodes)
        File.open(FailureIsolation::CurrentNodesPath, "w") { |f| f.puts current_nodes.to_a.join("\n") }
        system "scp #{FailureIsolation::CurrentNodesPath} cs@toil:#{FailureIsolation::ToilNodesPath}"
    end

    def update_blacklist(blacklist)
        File.open(FailureIsolation::NodeBlacklistPath, "w") { |f| f.puts blacklist.to_a.join("\n") }
    end

    def update_target_blacklist(blacklist)
        File.open(FailureIsolation::TargetBlacklistPath, "w") { |f| f.puts blacklist.to_a.join("\n") }
    end
end

if $0 == __FILE__
    sorted_pops, sortedpopcore, sortedpopedge = generate_top_pops(false)
    $stderr.puts sortedpopcore.inspect
    $stderr.puts sortedpopedge.inspect
end
