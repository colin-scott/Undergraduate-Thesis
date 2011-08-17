#!/homes/network/revtr/ruby/bin/ruby

require 'failure_monitor'
require 'failure_dispatcher'

f = FailureMonitor.new(FailureDispatcher.new)

f.swap_out_faulty_nodes
