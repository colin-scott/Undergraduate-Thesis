#!/homes/network/revtr/ruby/bin/ruby

# last_responsive will be 
#    * "N/A" if not in the database
#    * false if not historically pingable
#    * A Time object if historically pingable
#    * nil if not initialized (not grabbed from the
#       DB yet)

require 'mysql'
require 'mysql_connection_manager'
require 'socket'
require 'utilities'
require 'set'
require 'failure_isolation_consts'

# TODO: make all static sql queries class variables
class DatabaseInterface
    def initialize(logger=$stderr, host="bouncer.cs.washington.edu", usr="revtr", pwd="pmep@105&rws", database="revtr")
        @logger = logger

        begin
            @connection = MysqlConnectionManager.new(host, usr, pwd, database)
        rescue Mysql::Error
            @logger.puts "DB connection error " + host
            throw e
        end

        @hostname2ip = hostname2ip
        @ip2hostname = ip2hostname
    end
    
    # wrapper for arbitrary sql queries
    def query(sql)
        results = @connection.query sql
    end

    def node_hostname(ip)
        hostname = nil
        ip_int = Inet::aton(ip)
        sql = "select vantage_point from vantage_points where IP=#{ip_int};"
        
        results = query(sql)

        results.each_hash do |row|
            hostname = row["vantage_point"]
        end

        return hostname
    end

    def node_ip(node)
        ip = nil
        sql = "select inet_ntoa(IP) as ip from vantage_points where vantage_point='#{node}';" 
        
        results = query(sql)

        results.each_hash do |row|
            ip = row["ip"]
        end

        return ip 
    end

    def hostname2ip()
        return @hostname2ip unless @hostname2ip.nil?

        hostname2ip = Hash.new do |h,k| 
            result = nil
            if k.respond_to?(:downcase) and h.include? k.downcase 
                result = h[k.downcase]
            elsif !k.respond_to?(:matches_ip?) or !k.matches_ip?
                raise "unknown hostname #{k}"
            else
                result = k
            end

            result
        end

        sql = "select vantage_point, inet_ntoa(IP) as ip from vantage_points;"
        
        results = query(sql)

        results.each_hash do |row|
            hostname2ip[row["vantage_point"].downcase] = row["ip"]
        end

        hostname2ip
    end

    def ip2hostname()
        return @ip2hostname unless @ip2hostname.nil?

        sql = "select vantage_point, inet_ntoa(IP) as ip from vantage_points;"
        
        ip2hostname = Hash.new { |h,k| k }

        results = query(sql)

        results.each_hash do |row|
            ip2hostname[row["ip"]] = row["vantage_point"]
        end

        return ip2hostname
    end

    # return hash from ip -> last_responsive
    def fetch_pingability(ips)
        raise "ips can't be nil!" if ips.nil?

        only_ips = ips.map { |ip| ip.is_a?(String) ? @hostname2ip[ip] : ip }.find_all { |elt| !elt.nil? }
        raise "ips not ips! #{ips.inspect}" if only_ips.find { |ip| !ip.matches_ip? and !ip.is_a?(Integer) }

        #@logger.puts "fetch_pingability(), ips=#{ips.inspect}"
        addrs = only_ips.map { |ip| ip.is_a?(String) ? Inet::aton(ip) : ip }
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
        
        results = Set.new(query(sql)).to_a

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
            bad_srcs << @ip2hostname[Inet::ntoa(src.to_i)] 
          elsif states2count.length > 1 and states2count.include?("dst_not_reachable")
            sum = states2count.values.inject( nil ) { |sum,x| sum ? sum+x : x }
            if (states2count["reached"]+states2count["in_progress"])/(sum*1.0) < 0.5
              possibly_bad_srcs << @ip2hostname[Inet::ntoa(src.to_i)] 
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

    # returns {hostname -> IP addresses}
    def uncontrollable_isolation_vantage_points()
        hostname2ip = {}
        sql = "select vantage_point, inet_ntoa(IP) as ip from isolation_vantage_points where sshable=0 or controllable=0;"

        results = query sql
        results.each_hash{|row|
          hostname2ip[row["vantage_point"]] = row["ip"]
        }

        hostname2ip
    end

    # returns {hostname -> IP addresses}
    def controllable_isolation_vantage_points()
        hostname2ip = {}
        sql = "select vantage_point, inet_ntoa(IP) as ip from isolation_vantage_points where sshable=1 and controllable=1;"

        results = query sql
        results.each_hash{|row|
          hostname2ip[row["vantage_point"]] = row["ip"]
        }

        hostname2ip
    end
end

if $0 == __FILE__
    db = DatabaseInterface.new
    # puts db.fetch_pingability(ARGV).inspect
    puts db.node_hostname("38.98.51.15")
end
