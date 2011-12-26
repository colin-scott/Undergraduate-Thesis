#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << "../"

require 'isolation_module' # Don't want to have to load this...
require 'failure_monitor'

monitor = FailureMonitor.new

outage_state = { "1.2.3.4" => 20 }
connected_state = {}
node2targetstate = { "froo.froo" => outage_state, 
                     "frooz.frooz" => outage_state, 
                     "fram.fram" => connected_state }

target2observingnode2rounds, target2neverseen, target2stillconnected = monitor.classify_outages(node2targetstate, true)
$stderr.puts "target2observingnode2rounds #{target2observingnode2rounds}"
$stderr.puts "target2neverseen #{target2neverseen}" 
$stderr.puts "target2stillconnected #{target2stillconnected}"

srcdst2outage, dst2filter_tracker = monitor.send_notification(target2observingnode2rounds, target2neverseen, target2stillconnected)

$stderr.puts "srcdst2outage #{srcdst2outage}"
$stderr.puts "dst2filter_tracker #{dst2filter_tracker}"

# TODO: assert that output matches expected
