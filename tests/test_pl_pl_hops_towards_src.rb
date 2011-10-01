#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'isolation_module'
require 'drb'
require 'outage_correlation'
require 'failure_analyzer'
require 'outage'
require 'db_interface'

require 'utilities'
Thread.abort_on_exception = true
log = LoggerLog.new($stderr)

hosts = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri).hosts.sort_by { rand }.clone
src = hosts.shift
receivers = hosts[0..5]

db = DatabaseInterface.new

if FailureIsolation::current_hops_on_pl_pl_traces_to_src_ip(db.node_ip(src)).find { |h| h =~ /size/ }
    puts src
end
