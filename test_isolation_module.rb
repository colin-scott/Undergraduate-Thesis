#!/homes/network/revtr/ruby/bin/ruby

require 'isolation_module'
dispatcher = FailureDispatcher.new
if ARGV.empty?
    dispatcher.isolate_outage("planetlab-node3.it-sudparis.eu", "195.178.99.1",
               ["pl1.6test.edu.cn", "planetlab2.eecs.umich.edu", "planetlab1.nvlab.org",
                  "plgmu4.ite.gmu.edu", "75-130-96-12.static.oxfr.ma.charter.com"])
else
    dispatcher.isolate_outage(ARGV.shift, ARGV.shift, ARGV.map { |str| str.gsub(/,$/, '') }, true)
end

sleep 30
