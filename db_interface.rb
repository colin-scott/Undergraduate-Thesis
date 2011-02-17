#!/homes/network/revtr/ruby/bin/ruby

require 'mysql'
require 'socket'
require 'utilities'
require '../spooftr_config'

class DatabaseInterface
    def initialize
        @@db_host = 'bouncer.cs.washington.edu'
        @@user = 'revtr'
        @@password = 'pmep@105&rws'
        @@db = 'revtr'
        connect()
    end

    # return hash from ip -> last_responsive
    def fetch_pingability(ips)
        $stderr.puts "fetch_pingability(), ips=#{ips.inspect}"
        addrs = ips.map{ |ip| ip.is_a?(String) ? Inet::aton($pl_host2ip[ip]) : ip }
        $stderr.puts "fetch_pingability(), addrs=#{ips.inspect}"
        responsive = Hash.new { |h,k| h[k] = "N/A" }

        sql = "select * from pingability where ip=#{addrs.join " OR ip=" }"
        
        results = issue_query(sql)

        $stderr.puts "fetch_pingability(), results=#{results.inspect}"

        results.each_hash do |row|
           $stderr.puts "fetch_pingability(), row=#{row.inspect}"
           responsive[Inet::ntoa(row["ip"].to_i)] = row["last_responsive"]
        end

        responsive
    end

    private

    def issue_query(sql)
        results = @connection.query sql
    end
    
    def connect()
        begin
              @connection = Mysql.new(@@db_host, @@user, @@password, @@db)
        rescue Mysql::Error => e
              $stderr.puts "DB connection error #{@@db_host} #{e}"
              throw e
        end
    end
end

if $0 == __FILE__
    db = DB.new
    puts db.fetch_pingability(ARGV).inspect
end
