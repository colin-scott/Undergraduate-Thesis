#!/homes/network/revtr/ruby/bin/ruby

require 'isolation_module'
require 'set'
require 'mysql'
require 'mail'
require 'socket'
require 'utilities'

# TODO: merge with faulty VP report
class Emailer < ActionMailer::Base
  def isolation_status(email,bad_srcs,p_bad_srcs,bad_dsts,p_bad_dsts,bad_dsts_ep,p_bad_dsts_ep)
    subject     "Isolation status: reverse path probing"
    from        "revtr@cs.washington.edu"
    recipients  email
    body        :bad_srcs => bad_srcs.join("<br />"), :bad_dsts => bad_dsts.join("<br />"),
    :possibly_bad_srcs => p_bad_srcs.join("<br />"), :possibly_bad_dsts => p_bad_dsts.join("<br />"),
    :possibly_bad_dsts_ep => p_bad_dsts_ep.join("<br />"), :bad_dsts_ep => bad_dsts_ep.join("<br />")
  end
end

module HouseCleaning
    # returns a tuple
    #   First, sorted pop #s by degree
    #   Second, pop2corertrs
    #     { pop -> [corertr1, corertr2...] }
    #   Third, pop2edgertrs
    #     { pop -> [edgertr1, edgertr2...] }
    def self.generate_top_pops(regenerate=true)
        system "#{FailureIsolation::TopPoPsScripts} #{FailureIsolation::NumTopPoPs}" if regenerate

        sorted_pops = IO.read(FailureIsolation::TopN).split("\n").map { |line| line.split[0].to_sym } 
        pops_set = Set.new(sorted_pops)

        # generate pop, core mappings
        pop2corertrs = Hash.new { |h,k| h[k] = [] }
        FailureIsolation::IPToPoPMapping.each do |ip, pop|
            pop2corertrs[pop] << ip if pops_set.include? pop and !FailureIsolation::TargetBlacklist.include? ip
        end

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

        currently_used_pops = Set.new(FailureIsolation::HarshaPoPs.map { |ip| FailureIsolation::IPToPoPMapping[ip] })

        sorted_replacement_pops = sorted_pops.find_all { |pop| !currently_used_pops.include? pop }

        [sorted_replacement_pops, pop2corertrs, pop2edgertrs]
    end

    def self.refill_pops(dataset, num_rtrs_per_pop, pop2replacements, sorted_replacement_pops)
        chosen_replacements = []
        dataset2pop2unresponsivetargets[dataset].each do |pop2unresponsivetargets|
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
        end 
        chosen_replacements
    end

    def self.find_substitutes_for_unresponsive_targets
        dataset2substitute_targets = Hash.new { |h,k| h[k] = Set.new }

        bad_hops, possibly_bad_hops, bad_targets, possibly_bad_targets = @db.check_target_probing_status()
        # TODO: do something with bad_hops
        
        dataset2pop2unresponsivetargets = Hash.new { |h,k| h[k] = Hash.new { |h1,k1| h1[k1] = [] } }

        bad_targets.each do |target|
            # identify which dataset it came from
            dataset = FailureIsolation::get_dataset(target) 
            raise "unknown target" if dataset == DataSets::Unknown

            pop = FailureIsolation::IPToPoPMapping[target]
            dataset2pop2unresponsivetargets[dataset][pop] << target
        end

        # =======================
        #   Harsha's PoPs       #
        # =======================
        
        sorted_replacement_pops, pop2corertrs, pop2edgertrs = HouseCleaning::generate_top_pops

        dataset2substitute_targets[DataSets::HarshaPoPs] = HouseCleaning::refill_pops(DataSets::HarshaPoPs, FailureIsolation::CoreRtrsPerPoP,
                                                    pop2corertrs, sorted_replacement_pops)
        dataset2substitute_targets[DataSets::BeyondHarshaPoPs] = HouseCleaning::refill_pops(DataSets::BeyondHarshaPoPs, FailureIsolation::EdgeRtrsPerPoP,
                                                    pop2edgertrs, sorted_replacement_pops)
         
        # =======================
        #  CloudFront           #
        # =======================
        
        #    is static

        # =======================
        #  Spoofers             #
        # =======================
        
        # what about pingability? I guess they will just be swapped out the
        # next round...
        #
        # TODO: update spoofers list, put into DB, select all sshable
         
        # also clear out spoofers that are consistently unresponsive to ssh.
        # spoofers are kept in the isolation_vantage_points table
        # and responsiveness to ssh is stored in the table!

        [dataset2substitute_targets, bad_targets, bad_hops, possible_bad_hops, possibly_bad_targets]
    end

    def self.swap_out_unresponsive_targets(bad_targets, dataset2substitute_targets)
        HouseCleaning::update_target_blacklist(bad_targets | FailureIsolation::Blacklist)

        dataset2substitute_targets.each do |dataset, substitute_targets|
            path = DataSets::ToPath(dataset)

            old_targets = IO.read(path).split("\n")
            new_targets = old_targets - bad_targets + substitute_targets
            File.open(path, "w") { |f| f.puts new_targets.join "\n" }
        end

        FailureIsolation::ReadInDataSets()
    end

    def self.find_substitute_vps()
        already_blacklisted = Set.new(IO.read(FailureIsolation::BlackListPath).split("\n"))

        to_swap_out = Set.new

        outdated = @outdated_nodes
        @outdated_nodes = {}
        to_swap_out |= outdated.map { |k,v| k }
        
        source_problems = @problems_at_the_source
        @problems_at_the_source = {}
        to_swap_out |= source_problems.keys

        not_sshable = @not_sshable
        @not_sshable = Set.new
        to_swap_out |= not_sshable

        # XXX clear node_2_failed_measurements state
        failed_measurements = @dispatcher.node_2_failed_measurements.find_all { |node,missed_count| missed_count > @@failed_measurement_threshold }
        to_swap_out |= failed_measurements.map { |k,v| k }

        bad_srcs, possibly_bad_srcs = @db.check_source_probing_status()
        to_swap_out += bad_srcs

        to_swap_out -= already_blacklisted

        return [to_swap_out,outdated,source_problems,not_sshable,
            failed_measurements,bad_srcs,possibly_bad_srcs,outdated]
    end

    def self.swap_out_faulty_nodes(faulty_nodes)
        all_nodes = Set.new(IO.read(FailureIsolation::AllNodesPath).split("\n"))
        blacklist = Set.new(IO.read(FailureIsolation::BlackListPath).split("\n"))
        current_nodes = Set.new(IO.read(FailureIsolation::CurrentNodesPath).split("\n"))
        available_nodes = (all_nodes - blacklist - current_nodes).to_a.sort_by { |node| rand }
        
        # XXX
        available_nodes.delete_if { |node| node =~ /mlab/ || node =~ /measurement-lab/ }
        
        faulty_nodes.each do |broken_vp|
            if !current_nodes.include? broken_vp
                $stderr.puts "#{broken_vp} not in current node set..."
                next 
            end
        
            current_nodes.delete broken_vp
            blacklist.add broken_vp
            system "echo #{broken_vp} > #{FailureIsolation::NodeToRemovePath} && pkill -SIGUSR2 -f run_failure_isolation.rb"
        end
        
        while current_nodes.size < FailureIsolation::NumActiveNodes
            new_vp = available_nodes.shift
            $stderr.puts "choosing: #{new_vp}"
            current_nodes.add new_vp
        end

        self.update_current_nodes(current_nodes)
        self.update_blacklist(blacklist)
        system "rm #{FailureIsolation::PingStatePath}/*"
    end

    def self.add_nodes(nodes)
        current_nodes = Set.new(IO.read(FailureIsolation::CurrentNodesPath).split("\n"))
        current_nodes |= nodes
        
        self.update_current_nodes(current_nodes)
    end

    def self.update_current_nodes(current_nodes)
        File.open(FailureIsolation::CurrentNodesPath, "w") { |f| f.puts current_nodes.to_a.join("\n") }
        system "scp #{FailureIsolation::CurrentNodesPath} cs@toil:#{FailureIsolation::ToilNodesPath}"
    end

    def self.update_blacklist(blacklist)
        File.open(FailureIsolation::BlackListPath, "w") { |f| f.puts blacklist.to_a.join("\n") }
    end

    def self.update_target_blacklist(blacklist)
        File.open(FailureIsolation::TargetBlackListPath, "w") { |f| f.puts blacklist.to_a.join("\n") }
    end
end

if $0 == __FILE__
    sorted_pops, sortedpopcore, sortedpopedge = HouseCleaning::generate_top_pops(false)
    $stderr.puts sortedpopcore.inspect
    $stderr.puts sortedpopedge.inspect
end
