#!/homes/network/revtr/ruby/bin/ruby

require 'isolation_module'
require 'set'
require 'mysql'
require 'mail'
require 'socket'
require 'utilities'
require 'db_interface'

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
        # Why the broken pipe?? XXX
        # possibly there is an EOF in there?
        @logger.debug "generating top pops..."
        system "#{FailureIsolation::TopPoPsScripts} #{FailureIsolation::NumTopPoPs}" if regenerate

        sorted_pops = IO.read(FailureIsolation::TopN).split("\n").map { |line| line.split[0].to_sym } 
        pops_set = Set.new(sorted_pops)

        # generate pop, core mappings
        pop2corertrs = Hash.new { |h,k| h[k] = [] }
        FailureIsolation::IPToPoPMapping.each do |ip, pop|
            pop2corertrs[pop] << ip if pops_set.include? pop and !FailureIsolation::TargetBlacklist.include? ip
        end

        @logger.debug "core routers generated"

        # generate pop, edge mappings
        popsrcdsts = IO.read(FailureIsolation::SourceDests).split("\n")\
                        .map { |line| line.split }.map { |triple| [triple[0].to_sym, triple[1,2]] }
        # TODO: filter out core routers?
                        
        # only grab edge routers seen from at least one of our VPs
        current_vps = Set.new(IO.read(FailureIsolation::CurrentNodesPath).split("\n")\
                              .map { |node| $pl_host2ip[node] })

        pop2edgertrs = Hash.new { |h,k| h[k] = [] }
        popsrcdsts.each do |popsrcdst| 
            pop, srcdst = popsrcdst
            next unless pops_set.include? pop # should be included...
            src, dst = srcdst
            next unless current_vps.include? src
            pop2edgertrs[pop] << dst unless FailureIsolation::TargetBlacklist.include? dst
        end

        @logger.debug "edge routers generated"

        currently_used_pops = Set.new(FailureIsolation::HarshaPoPs.map { |ip| FailureIsolation::IPToPoPMapping[ip] })

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

        bad_hops, possibly_bad_hops, bad_targets, possibly_bad_targets = @db.check_target_probing_status(FailureIsolation::TargetSet)
        # TODO: do something with bad_hops
        @logger.debug "bad_hops: #{bad_hops}"
        @logger.debug "bad_targets: #{bad_targets}"
        
        dataset2unresponsive_targets = Hash.new { |h,k| h[k] = [] }

        bad_targets.each do |target|
            @logger.debug ". #{target} identifying"
            # identify which dataset it came from
            dataset = FailureIsolation::get_dataset(target) 
            if dataset == DataSets::Unknown
                @logger.warn "unknown target #{target}" 
                next
            end

            dataset2unresponsive_targets[dataset] << target
        end

        @logger.debug "dataset2unresponsive_targets: #{dataset2unresponsive_targets.inspect}"

        # =======================
        #   Harsha's PoPs       #
        # =======================
        
        sorted_replacement_pops, pop2corertrs, pop2edgertrs = generate_top_pops

        # (see utilities.rb for .categorize())
        core_pop2unresponsivetargets = dataset2unresponsive_targets[DataSets::HarshaPoPs]\
                                        .categorize(FailureIsolation::IPToPoPMapping, DataSets::Unknown)
        dataset2substitute_targets[DataSets::HarshaPoPs] = refill_pops(core_pop2unresponsivetargets,
                                                                             FailureIsolation::CoreRtrsPerPoP,
                                                                             pop2corertrs, sorted_replacement_pops)
        @logger.debug "Harsha PoPs substituted"
        
        # (see utilities.rb for .categorize())
        edge_pop2unresponsivetargets = dataset2unresponsive_targets[DataSets::BeyondHarshaPoPs].categorize(FailureIsolation::IPToPoPMapping, DataSets::Unknown)
        dataset2substitute_targets[DataSets::BeyondHarshaPoPs] = refill_pops(edge_pop2unresponsivetargets,
                                                                                   FailureIsolation::EdgeRtrsPerPoP,
                                                                                   pop2edgertrs, sorted_replacement_pops)

        @logger.debug "Edge PoPs substituted"
         
        # =======================
        #  CloudFront           #
        # =======================
        
        #    is static

        # =======================
        #  Spoofers             #
        # =======================
        
        unresponsive_spoofers = dataset2unresponsive_targets[DataSets::SpooferTargets] 
        dataset2substitute_targets[DataSets::SpooferTargets] = @db.controllable_isolation_vantage_points.values
        #  Only filter out faulty /isolation nodes/ not faulty vps
         
        [dataset2substitute_targets, dataset2unresponsive_targets,
            possibly_bad_targets, bad_hops, possibly_bad_hops]
    end

    # TODO: separate this into two methods: remove, and substitute
    # precondition: bad_targets are a subset of the current datasets
    def swap_out_unresponsive_targets(dataset2unresponsive_targets, dataset2substitute_targets)
        bad_targets = dataset2unresponsive_targets.is_a?(Hash) ? \
                       dataset2unresponsive_targets.value_set : \
                       dataset2unresponsive_targets 

        @logger.debug "swapping out unresponsive targets: #{bad_targets}"

        update_target_blacklist(bad_targets.to_set | FailureIsolation::TargetBlacklist)
        @logger.debug "blacklist updated"

        dataset2substitute_targets.each do |dataset, substitute_targets|
            path = DataSets::ToPath(dataset)

            old_targets = Set.new IO.read(path).split("\n")
            new_targets = (old_targets - bad_targets.to_set + substitute_targets.to_set)
            File.open(path, "w") { |f| f.puts new_targets.join "\n" }
        end

        FailureIsolation::ReadInDataSets()

        @logger.debug "target lists updated"
    end

    # TODO: grab subtitute nodes from the database, not the static file
    # TODO: make the blacklist site-specific, not host-specific
    def swap_out_faulty_nodes(faulty_nodes)
        @logger.debug "swapping out faulty nodes: #{faulty_nodes}"

        all_nodes = Set.new(@db.controllable_isolation_vantage_points.keys)
        blacklist = FailureIsolation::NodeBlacklist
        current_nodes = FailureIsolation::CurrentNodes
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
            @logger.debug "choosing: #{new_vp}"
            current_nodes.add new_vp
        end

        update_current_nodes(current_nodes)
        update_blacklist(blacklist)
        FailureIsolation::ReadInNodeSets()

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
