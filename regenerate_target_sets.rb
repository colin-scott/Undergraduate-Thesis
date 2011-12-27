#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << "./"

# Proactively regenerate target sets (useful when tweaking parameters in
# failure_isolation_consts.rb)
#
# Normally targets are regerneated once a day

$stderr.puts "Loading Modules..."
require 'failure_monitor'

monitor = FailureMonitor.new
monitor.swap_out_unresponsive_targets
