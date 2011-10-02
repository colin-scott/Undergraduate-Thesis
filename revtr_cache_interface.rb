#!/homes/network/revtr/ruby/bin/ruby

require 'failure_isolation_consts'
require 'db_interface'
require 'socket'
require 'utilities'
require 'ip_info'
require 'hops'

class RevtrCache
    @@freshness = 24*60
    @@max_hops = 30
    @@do_remapping = false

    def initialize(ipInfo=IpInfo.new, database=DatabaseInterface.new, logger=LoggerLog.new($stderr))
        @ipInfo = ipInfo
        @db = database
        @connection = @db
        @logger = logger
    end

    def get_cached_reverse_path(src, dst)
      path = HistoricalReversePath.new
      path.src = src
      path.dst = dst
    
      src = Inet::aton(@db.hostname2ip[src])
      dst = Inet::aton(dst)
      old_dst = dst
      ts = 0
    
      # find matching revtrs
      begin
    
        sql = "select * from cache_rtrs where src=#{src} and dest=#{dst} "
        if (@@freshness > 0) then
          buffer = @@freshness
          #if max_staleness > 0 and max_staleness > @@freshness then buffer = max_staleness else buffer=@@freshness end
          sql += " and date > from_unixtime(#{Time.now.to_i-(buffer*60)})"
        end
        sql += " order by date desc limit 11"
    
        # no match, try remapping to next hop
        results = @connection.query sql
        if results.num_rows() == 0
        if @@do_remapping
          sql = "select inet_ntoa(endpoint) as e, last_hop from endpoint_mappings where src=#{src} and endpoint=#{dst} limit 1"
          results = @connection.query sql
          if results.num_rows() > 0
            results.each_hash{|row|
              old_dst = dst
              dst = row["last_hop"].to_i
            }
            @logger.debug "No matches for #{Inet::ntoa(old_dst)}, remapping endpoint to #{Inet::ntoa(dst)}"
          end
    
          sql = "select * from cache_rtrs where src=#{src} and dest=#{dst} "
          if (@@freshness > 0) then
            buffer = @@freshness
            #if max_staleness > 0 and max_staleness > @@freshness then buffer = max_staleness else buffer=@@freshness end
            sql += " and date > from_unixtime(#{Time.now.to_i-(buffer*60)})"
          end
          sql += " order by date desc limit 11"
    
          # still no match, so output the status for probing this node
          results = @connection.query sql
        end # end if do_remapping
          if results.num_rows() == 0
            reason = "not yet attempted"
            sql = "select state, lastUpdate from isolation_target_probe_state where src=" +
            "#{src} and dst=#{dst}"
            #          @logger.puts sql
            begin
              results = @connection.query sql
              results.each_hash{|row|
                reason = row["state"] + " at " + row["lastUpdate"]
              }
            rescue Mysql::Error
              @logger.warn "Error with query: #{sql}"
              @logger.puts $!
            end
    
            @logger.debug "No matches in the past #{@@freshness} minutes!\nProbe status: #{reason}"
    
            path.valid = false
            path.invalid_reason = reason
    
            return path
          end
        end # results.num_rows() == 0
        
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
      rescue Mysql::Error
        @logger.puts "Error with query: #{sql}"
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
      if sym_results.num_rows() > 0
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
      end # end if sym_results.num_rows()

      return reasons
   end
end

if $0 == __FILE__
  connection = DatabaseInterface.new
  cache = RevtrCache.new(connection, IpInfo.new)

#  if ARGV.empty?
#    $stderr.puts "Usage: #{$0} <src ip> <dst ip>"
#    exit
#  end
#
#  src = ARGV.shift
#  dst = ARGV.shift
#  print_cached_reverse_path(src,dst)

# find and print some live ones, comment this stuff out for use with other code
done = false
while not done

#    puts $pl_host2ip
#    ["159.148.236.1","129.250.3.197"].each{|dst|
#    puts $pl_host2ip["planetlab-01.kusa.ac.jp"]
#        path = cache.get_cached_reverse_path("planetlab-01.kusa.ac.jp", dst);
#  $stderr.puts path.inspect
#  puts path
#    }
#exit
  begin

    sql = "select * from cache_rtrs where date > "+
    "from_unixtime(#{Time.now.to_i-(12*60*60)}) order by rand() limit 10"

    results = connection.query sql
    skip = true
    results.each_hash{|row|
      30.times{|i|
        type = row["type"+(i+1).to_s].to_i
        if type==7 then skip = false end
      }
      if not skip
        path = cache.get_cached_reverse_path($pl_ip2host[Inet::ntoa(row["src"].to_i)],
                    Inet::ntoa(row["dest"].to_i))
        $stderr.puts path.inspect
        puts path
        done = true
      end
    }
  rescue Mysql::Error
    puts "DB connection error" + $db_host
  end
end # while not done

end
