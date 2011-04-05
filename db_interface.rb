#!/homes/network/revtr/ruby/bin/ruby

require 'mysql'
require 'socket'
require 'utilities'
require '../spooftr_config'

class DatabaseInterface
    def initialize(host="bouncer.cs.washington.edu", usr="revtr", pwd="pmep@105&rws", database="revtr")
        begin
          @connection = Mysql.new(host, usr, pwd, database)
        rescue Mysql::Error => e
          $stderr.puts "DB connection error " + host
          throw e
        end
    end
    
    # return hash from ip -> last_responsive
    def fetch_pingability(ips)
        $stderr.puts "fetch_pingability(), ips=#{ips.inspect}"
        addrs = ips.map{ |ip| ip.is_a?(String) ? Inet::aton($pl_host2ip[ip]) : ip }
        $stderr.puts "fetch_pingability(), addrs=#{ips.inspect}"
        responsive = Hash.new { |h,k| h[k] = "N/A" }

        sql = "select * from pingability where ip=#{addrs.join " OR ip=" }"
        
        results = query(sql)

        $stderr.puts "fetch_pingability(), results=#{results.inspect}"

        results.each_hash do |row|
           $stderr.puts "fetch_pingability(), row=#{row.inspect}"
           #   see hops.rb for an explanation:
           row["last_responsive"] = false if row["last_responsive"].nil?
           responsive[Inet::ntoa(row["ip"].to_i)] = row["last_responsive"]
        end

        responsive
    end

    # wrapper for arbitrary sql queries
    def query(sql)
        results = @connection.query sql
    end
end

if $0 == __FILE__
    db = DB.new
    puts db.fetch_pingability(ARGV).inspect
end
