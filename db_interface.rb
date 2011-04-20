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
    def initialize(host="bouncer.cs.washington.edu", usr="revtr", pwd="pmep@105&rws", database="revtr")
        begin
          @connection = Mysql.new(host, usr, pwd, database)
        rescue Mysql::Error => e
          $LOG.puts "DB connection error " + host
          throw e
        end
    end
    
    # return hash from ip -> last_responsive
    def fetch_pingability(ips)
        #$LOG.puts "fetch_pingability(), ips=#{ips.inspect}"
        addrs = ips.map{ |ip| ip.is_a?(String) ? Inet::aton($pl_host2ip[ip]) : ip }
        #$LOG.puts "fetch_pingability(), addrs=#{ips.inspect}"
        responsive = Hash.new { |h,k| h[k] = "N/A" }

        return responsive if addrs.empty?

        sql = "select * from pingability where ip=#{addrs.join " OR ip=" }"
        
        results = query(sql)

        #$LOG.puts "fetch_pingability(), results=#{results.inspect}"

        results.each_hash do |row|
           #$LOG.puts "fetch_pingability(), row=#{row.inspect}"
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

    # wrapper for arbitrary sql queries
    def query(sql)
        results = @connection.query sql
    end
end

if $0 == __FILE__
    db = DatabaseInterface.new
    puts db.fetch_pingability(ARGV).inspect
end
