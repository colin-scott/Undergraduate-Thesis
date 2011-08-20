#!/homes/network/revtr/ruby/bin/ruby

# last_responsive will be 
#    * "N/A" if not in the database
#    * false if not historically pingable
#    * A Time object if historically pingable
#    * nil if not initialized (not grabbed from the
#       DB yet)

require 'mysql'
require 'socket'
require 'utilities'
require 'set'
require 'isolation_module'

class DatabaseInterface
    def initialize(logger=$stderr, host="bouncer.cs.washington.edu", usr="revtr", pwd="pmep@105&rws", database="revtr")
        @logger = logger
        begin
          @connection = Mysql.new(host, usr, pwd, database)
        rescue Mysql::Error => e
          @logger.puts "DB connection error " + host
          throw e
        end
    end
    
    # wrapper for arbitrary sql queries
    def query(sql)
        results = @connection.query sql
    end

    # return hash from ip -> last_responsive
    def fetch_pingability(ips)
        #@logger.puts "fetch_pingability(), ips=#{ips.inspect}"
        addrs = ips.map{ |ip| ip.is_a?(String) ? Inet::aton($pl_host2ip[ip]) : ip }
        #@logger.puts "fetch_pingability(), addrs=#{ips.inspect}"
        responsive = Hash.new { |h,k| h[k] = "N/A" }

        return responsive if addrs.empty?

        sql = "select * from pingability where ip=#{addrs.join " OR ip=" }"
        
        results = query(sql)

        #@logger.puts "fetch_pingability(), results=#{results.inspect}"

        results.each_hash do |row|
           #@logger.puts "fetch_pingability(), row=#{row.inspect}"
           #   see hops.rb for an explanation:
           row["last_responsive"] = false if row.include?("last_responsive") and row["last_responsive"].nil?
           responsive[Inet::ntoa(row["ip"].to_i)] = row["last_responsive"]
        end

        responsive
    end

    # fetch all reverse hops from the cache
    def fetch_reverse_hops()
        sql = "select distinct inet_ntoa(hop) from cache_hops where date < (current_timestamp()-24*60*60)"
        
        results = Set.new(query(sql))

        # convert (singleton) arrays into the the strings they contain
        results.map { |hop| hop[0] }
    end

    def check_source_probing_status()
        sql = "select src, state, count(*) as c from isolation_target_probe_state "+
        "where lastUpdate>from_unixtime(#{Time.now.to_i - 12*60*60}) group by src,state"
        src2states = Hash.new{|h,k| h[k] = Hash.new{|h1,k1| h1[k1] = 0}}
        results = query sql
        results.each_hash{|row|
          src2states[row["src"]][row["state"]] = row["c"].to_i
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
    def check_target_probing_status(endhosts)
        # do analysis by destination
        sql = "select dst, state, count(*) as c from isolation_target_probe_state "+
        "where lastUpdate>from_unixtime(#{Time.now.to_i - 12*60*60}) group by dst,state"
        dst2states = Hash.new{|h,k| h[k] = Hash.new{|h1,k1| h1[k1] = 0}}
        results = query sql
        results.each_hash{|row|
          dst2states[row["dst"]][row["state"]] = row["c"].to_i
        }
        
        bad_dsts = []
        possibly_bad_dsts = []
        bad_dsts_ep = []
        possibly_bad_dsts_ep = []
        dst2states.each{|dst,states2count|
          if states2count.length == 1 and states2count.include?("dst_not_reachable") and states2count["dst_not_reachable"] > 5
            if endhosts.include?(dst.to_i) then bad_dsts_ep << Inet::ntoa(dst.to_i)
                else bad_dsts << Inet::ntoa(dst.to_i) end
          elsif states2count.length > 1 and states2count.include?("dst_not_reachable")
            sum = states2count.values.inject( nil ) { |sum,x| sum ? sum+x : x }
            if sum > 5 and (states2count["reached"]+states2count["in_progress"])/(sum*1.0) < 0.5 
                if endhosts.include?(dst.to_i) then possibly_bad_dsts_ep << Inet::ntoa(dst.to_i)
                   else possibly_bad_dsts << Inet::ntoa(dst.to_i) end
                 end
          end
        }

        [bad_dsts,possibly_bad_dsts,bad_dsts_ep,possibly_bad_dsts_ep]
    end
end

if $0 == __FILE__
    db = DatabaseInterface.new
    puts db.fetch_pingability(ARGV).inspect
end
