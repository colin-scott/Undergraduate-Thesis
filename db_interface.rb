#!/homes/network/revtr/ruby-upgrade/bin/ruby

# Ruby interface to the revtr database running on Bouncer.
#
# All of isolation's queries to the DB should proceed through this module, including 
# ad-hoc.

# last_responsive will be 
#    * "N/A" if not in the database
#    * false if not historically pingable
#    * A Time object if historically pingable
#    * nil if not initialized (not grabbed from the
#       DB yet)

if RUBY_PLATFORM == "java"
    require "mysql_connection_manager_jdbc"
else
    require 'mysql_connection_manager'
end

require 'ip_info'
require 'hops'
require 'socket'
require 'isolation_utilities'
require 'set'
require 'failure_isolation_consts'

# TODO: make all static sql queries class variables
class DatabaseInterface
    # For the revtr_cache. TODO: encapsulate me
    # ruby, do you have a Integer.infinity constant?:
    @@freshness_minutes = -1
    @@max_hops = 30
    @@do_remapping = false

    def initialize(logger=LoggerLog.new($stderr), ip_info=IpInfo.new, host="bouncer.cs.washington.edu", usr="revtr", pwd="pmep@105&rws", database="revtr")
        @logger = logger
        @ipInfo = ip_info

        begin
            @connection = MysqlConnectionManager.new(host, usr, pwd, database)
        rescue Mysql::Error
            @logger.info { "DB connection error " + host }
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

        #@logger.info { "fetch_pingability(), ips=#{ips.inspect}" }
        addrs = only_ips.map { |ip| ip.is_a?(String) ? Inet::aton(ip) : ip }
        #@logger.info { "fetch_pingability(), addrs=#{ips.inspect}" }
        responsive = Hash.new { |h,k| h[k] = "N/A" }

        return responsive if addrs.empty?

        sql = "select * from pingability where ip=#{addrs.join " OR ip=" }"
        
        results = query(sql)

        #@logger.info { "fetch_pingability(), results=#{results.inspect}" }

        results.each_hash do |row|
           #@logger.info { "fetch_pingability(), row=#{row.inspect}" }
           #   see hops.rb for an explanation:
           row["last_responsive"] = false if row.include?("last_responsive") and row["last_responsive"].nil?
           responsive[Inet::ntoa(row["ip"].to_i)] = row["last_responsive"]
        end

        responsive
    end

    # fetch all reverse hops from the cache
    def fetch_reverse_hops()
        sql = "select distinct inet_ntoa(hop) from cache_hops where date > (current_timestamp()-7*24*60*60)"
        
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
            state = row["state"]
            # merge deadend into dst_not_reachable for cases where we continue
            # after traceroute fails
            if state == "deadend" then state = "dst_not_reachable" end
            dst2states[row["dst"]][state] = row["c"].to_i
        }
        
        bad_dsts = []
        possibly_bad_dsts = []
        bad_dsts_ep = []
        possibly_bad_dsts_ep = []

        dst2states.each do |dst,states2count|
          if states2count.length == 1 and states2count.include?("dst_not_reachable") and states2count["dst_not_reachable"] > 5
            if endhosts.include?(dst.to_i)
                bad_dsts_ep << Inet::ntoa(dst.to_i)
            else
                bad_dsts << Inet::ntoa(dst.to_i)
            end
          elsif states2count.length > 1 and states2count.include?("dst_not_reachable")
            sum = states2count.values.inject( nil ) { |sum,x| sum ? sum+x : x }
            if sum > 5 and (states2count["reached"]+states2count["in_progress"])/(sum*1.0) < 0.5 
              if endhosts.include?(dst.to_i)
                  possibly_bad_dsts_ep << Inet::ntoa(dst.to_i)
              else
                  possibly_bad_dsts << Inet::ntoa(dst.to_i)
              end
            end
          end
        end

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
    
    # Return a HistoricalReversePath for the given src, dst, pair. Finds the
    # most recent cached reverse path. If none exist, puts failure reasons
    # into the reverse path and returns an empty HistoricalReversePath object
    def get_cached_reverse_path(src, dst)
      path = HistoricalReversePath.new(src, dst)
    
      src = Inet::aton(hostname2ip[src])
      dst = Inet::aton(dst)
      old_dst = dst
      ts = 0
    
      # find matching revtrs
      begin
    
        sql = "select * from cache_rtrs where src=#{src} and dest=#{dst} "
        if (@@freshness_minutes > 0) then
          buffer = @@freshness_minutes
          #if max_staleness > 0 and max_staleness > @@freshness_minutes then buffer = max_staleness else buffer=@@freshness_minutes end
          sql += " and date > from_unixtime(#{Time.now.to_i-(buffer*60)})"
        end
        sql += " order by date desc limit 11"
    
        # no match, try remapping to next hop
        results = @connection.query sql
        if not results.next
        if @@do_remapping
          sql = "select inet_ntoa(endpoint) as e, last_hop from endpoint_mappings where src=#{src} and endpoint=#{dst} limit 1"
          results = @connection.query sql
          if not not results.next 
            results.each_hash{|row|
              old_dst = dst
              dst = row["last_hop"].to_i
            }
            @logger.debug { "No matches for #{Inet::ntoa(old_dst)}, remapping endpoint to #{Inet::ntoa(dst)}" }
          end
    
          sql = "select * from cache_rtrs where src=#{src} and dest=#{dst} "
          if (@@freshness_minutes > 0) then
            buffer = @@freshness_minutes
            #if max_staleness > 0 and max_staleness > @@freshness_minutes then buffer = max_staleness else buffer=@@freshness_minutes end
            sql += " and date > from_unixtime(#{Time.now.to_i-(buffer*60)})"
          end
          sql += " order by date desc limit 11"
    
          # still no match, so output the status for probing this node
          results = @connection.query sql
        end # end if do_remapping
          if not results.next 
            reason = "not yet attempted"
            sql = "select state, lastUpdate from isolation_target_probe_state where src=" +
            "#{src} and dst=#{dst}"
            #          @logger.puts sql
            begin
              results = @connection.query sql
              results.each_hash{|row|
                reason = row["state"] + " at " + row["lastUpdate"]
              }
            rescue Exception
              @logger.warn { "Error with query: #{sql}" }
              @logger.puts $!
            end
    
            @logger.debug { "No matches in the past #{@@freshness_minutes} minutes!\nProbe status: #{reason}" }
    
            path.valid = false
            path.invalid_reason = reason
    
            return path
          end
        end # not results.next == 0
        
        # ok, we have results, let's start parsing them
        results.each_hash do |row|
          ts = row["date"]
          1.upto(@@max_hops) do |i|
            val = row["hop"+(i).to_s].to_i
            type = row["type"+(i).to_s].to_i
            case type
            when 1..2
              type = "rr"
            when 3..6
              type = "ts"
            when 7
              type = "sym"
            when 8
              type = "tr2src"
            when 9
              type = "dst-sym"
            else
              type = "unk"
            end

            reasons = nil

            if i > 1 and (type=="sym" or type=="dst-sym")
                reasons = get_symmetric_reasons(src, val)
            end 
                
            path << ReverseHop.new(Inet::ntoa(val), i, type, reasons, @ipInfo) if val > 0 or !path.empty? # empty hops also represented as 0
          end # 1.upto()

          break unless path.empty?
        end # results.each_hash
      rescue Exception
        @logger.info { "Error with query: #{sql}" }
        @logger.puts $!
      end # begin
    
      path.pop while !path.empty? and path[-1].ip=="0.0.0.0"
      path.valid = true if !path.empty?
      # all data has been generated, add it to the object for eventual return
      path.timestamp = ts
      return path
   end

   private

   def get_symmetric_reasons(src, hop)
      reasons = nil
      rr_non_spoof_responsive = "unknown"
      rr_spoof_responsive_count = 0
      rr_spoof_attempt = 0
      ts_non_spoof_responsive = "unknown"
      ts_spoof_responsive_count =  0
      ts_spoof_attempt = 0

      # "dest" is actually the hop being measured
      # in this case, we have to look from the previous hop
      sql = "select * from vp_stats where src=#{src} and dest=#{hop}"
      sym_results = @connection.query sql
      if not sym_results.next
        sym_results.each_hash{|row|
          sym_type = nil
          is_spoof = false
          is_rr = false
          case row["probe_type"].to_i
          when 1
            sym_type = "rr"
            is_rr = true
          when 2
            sym_type = "rr-spoof"
            is_rr = true
            is_spoof = true
          when 3
            sym_type = "ts"
          when 4
            sym_type = "ts-spoof"
            is_spoof = true
          when 6
            sym_type = "ts-spoof-ds"
            is_spoof = true
          else
            sym_type = nil
          end
          next if sym_type.nil?
    
          responsive = row["responsive"].to_i > 0 ? "yes" : "no"
          hop_count = row["hop_count"].to_i
          no_hop_found = row["no_hop_found"].to_i
          hops_found = row["hop_count_orig"].to_i
    
          if is_rr and not is_spoof then rr_non_spoof_responsive = responsive end
          if is_rr and is_spoof then
            if hop_count != 0 then rr_spoof_responsive_count += 1 end
            rr_spoof_attempt += 1
          end
    
          if sym_type=="ts" then
            ts_non_spoof_responsive = responsive
            if is_spoof then
              if hop_count != 0 then ts_spoof_responsive_count += 1 end
              ts_spoof_attempt += 1
            end
          end
    
          if is_rr and (row["rr_dst_unresponsive"].to_i>0) then responsive += " [dst unresponsive]" end
    
          ## not currently printed, but gives the complete picture
          #reasons << "#{sym_type} from #{$pl_ip2host[Inet::ntoa(row["vp"].to_i)]} "+
          #"responsive?: #{responsive} "+
          #"hop count: #{hop_count} raw hops: #{hops_found}"

          # let's simplify the text for output
          rr_spoof_text = rr_spoof_responsive_count>0 ? "partial" : (rr_spoof_attempt>0 ? "no" : "unknown")
          ts_spoof_text = ts_spoof_responsive_count>0 ? "partial" : (ts_spoof_attempt>0 ? "no" : "unknown")
          reasons = "non-spoof reachable: rr? #{rr_non_spoof_responsive} ts? #{ts_non_spoof_responsive} | "+
            "spoof: rr? #{rr_spoof_text} ts? #{ts_spoof_text}"
    
        } # end each_hash
      end # end if sym_not results.next

      return reasons
   end
end

if $0 == __FILE__
    db = DatabaseInterface.new
    # puts db.fetch_pingability(ARGV).inspect
    puts db.node_hostname("38.98.51.15")
    puts db.check_target_probing_status(FailureIsolation.TargetSet)
end
