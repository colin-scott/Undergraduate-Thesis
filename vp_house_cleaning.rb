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
            raise "no more nodes left to swap!" if available_nodes.empty?
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

    def self.check_source_probing_status(connection)
        sql = "select src, state, count(*) as c from isolation_target_probe_state "+
        "where lastUpdate>from_unixtime(#{Time.now.to_i - 12*60*60}) group by src,state"
        src2states = Hash.new{|h,k| h[k] = Hash.new{|h1,k1| h1[k1] = 0}}
        results = connection.query sql
        results.each_hash{|row|
          src2states[row["src"]][row["state"]] = row["c"].to_i
        }
        
        # get hops that are final targets or last hops
        endpoint_ips = Hash.new{|h,k| h[k] = false}
        sql = "select endpoint, last_hop from endpoint_mappings"
        results = connection.query sql
        results.each_hash{|row|
          endpoint_ips[row["endpoint"].to_i] = true
          endpoint_ips[row["last_hop"].to_i] = true
        }
        
        # find unreachable
        bad_srcs = []
        possibly_bad_srcs = []
        src2states.each{|src,states2count|
          if states2count.length == 1 and states2count.include?("dst_not_reachable")
            bad_srcs << $pl_ip2host[Inet::ntoa(src.to_i)] 
          elsif states2count.length > 1 and states2count.include?("dst_not_reachable")
            sum = states2count.values.inject( nil ) { |sum,x| sum ? sum+x : x }
            if (states2count["reached"]+states2count["in_progress"])/(sum*1.0) < 0.5
              possibly_bad_srcs << $pl_ip2host[Inet::ntoa(src.to_i)] 
            end
          end
        }
        
        [bad_srcs, possibly_bad_srcs]
    end

    # ep == "endpoint"
    def self.check_target_probing_status(connection)
        # do analysis by destination
        sql = "select dst, state, count(*) as c from isolation_target_probe_state "+
        "where lastUpdate>from_unixtime(#{Time.now.to_i - 12*60*60}) group by dst,state"
        dst2states = Hash.new{|h,k| h[k] = Hash.new{|h1,k1| h1[k1] = 0}}
        results = connection.query sql
        results.each_hash{|row|
          dst2states[row["dst"]][row["state"]] = row["c"].to_i
        }
        
        bad_dsts = []
        possibly_bad_dsts = []
        bad_dsts_ep = []
        possibly_bad_dsts_ep = []
        dst2states.each{|dst,states2count|
          if states2count.length == 1 and states2count.include?("dst_not_reachable") and states2count["dst_not_reachable"] > 5
            if endpoint_ips[dst.to_i] then bad_dsts_ep << $pl_ip2host[Inet::ntoa(dst.to_i)]
                else bad_dsts << Inet::ntoa(dst.to_i) end
          elsif states2count.length > 1 and states2count.include?("dst_not_reachable")
            sum = states2count.values.inject( nil ) { |sum,x| sum ? sum+x : x }
            if sum > 5 and (states2count["reached"]+states2count["in_progress"])/(sum*1.0) < 0.5 
              if endpoint_ips[dst.to_i] then possibly_bad_dsts_ep << Inet::ntoa(dst.to_i)
                   else possibly_bad_dsts << Inet::ntoa(dst.to_i) end
                 end
          end
        }

        [bad_dsts,possibly_bad_dsts,bad_dsts_ep,possibly_bad_dsts_ep]
    end
end
