require 'isolation_module'
require 'set'

module HouseCleaning
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

        File.open(FailureIsolation::CurrentNodesPath, "w") { |f| f.puts current_nodes.to_a.join("\n") }
        File.open(FailureIsolation::BlackListPath, "w") { |f| f.puts blacklist.to_a.join("\n") }
        system "scp #{FailureIsolation::CurrentNodesPath} cs@toil:#{FailureIsolation::ToilNodesPath}"
        system "rm #{FailureIsolation::PingStatePath}/*"
    end
end
