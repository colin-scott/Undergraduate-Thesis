if $0 == __FILE__
  connection = DatabaseInterface.new
  cache = RevtrCache.new(IpInfo.new,  connection)

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
  rescue Exception
    puts "DB connection error" + $db_host
  end
end # while not done

end
