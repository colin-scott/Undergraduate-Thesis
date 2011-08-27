#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'failure_monitor'
require 'failure_dispatcher'

logger = LoggerLog.new($stderr)
db = DatabaseInterface.new
f = FailureMonitor.new(FailureDispatcher.new(db, logger), db, logger)
logger.debug "starting..."

f.swap_out_unresponsive_targets
