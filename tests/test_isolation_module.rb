#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'failure_dispatcher'
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
    passed = dispatcher.isolate_outages({ srcdst => (ARGV.empty?) ? ["pl1.6test.edu.cn", "planetlab2.eecs.umich.edu", "planetlab1.nvlab.org",
                  "plgmu4.ite.gmu.edu", "deimos.cecalc.ula.ve"] :  ARGV.map { |str| str.gsub(/,$/, '')  }},
                               {srcdst => []}, {srcdst => []}, true)

    $stderr.puts "passed?: #{passed}"
end

$stderr.puts "#{Thread.list.inspect}"
sleep
