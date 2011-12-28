#!/homes/network/revtr/ruby-upgrade/bin/ruby

require 'failure_monitor'
require 'failure_dispatcher'

f = FailureMonitor.new(FailureDispatcher.new)

f.swap_out_faulty_nodes

# TODO: asserts
#
# =========== Target Swap =========
#$: << File.expand_path("../")
#
#require 'isolation_module'
#require 'failure_monitor'
#require 'failure_dispatcher'
#
#logger = LoggerLog.new($stderr)
#db = DatabaseInterface.new
#f = FailureMonitor.new(FailureDispatcher.new(db, logger), db, logger)
#logger.debug "starting..."
#
#f.swap_out_unresponsive_targets
