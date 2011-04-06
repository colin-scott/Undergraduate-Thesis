#!/homes/network/revtr/ruby/bin/ruby

require 'isolation_module'
dispatcher = FailureDispatcher.new

if ARGV.empty?
    srcdst = ["planetlab-node3.it-sudparis.eu", "132.252.152.193"]
    dispatcher.isolate_outages({ srcdst =>
               ["pl1.6test.edu.cn", "planetlab2.eecs.umich.edu", "planetlab1.nvlab.org",
                  "plgmu4.ite.gmu.edu", "deimos.cecalc.ula.ve"]},
               {srcdst => []}, {srcdst => []}, true)
else
    src = ARGV.shift
    dst = ARGV.shift
    srcdst = [src, dst]
    dispatcher.isolate_outages({ srcdst => ARGV.map { |str| str.gsub(/,$/, '')  }},
                               {srcdst => []}, {srcdst => []}, true)
end

sleep
