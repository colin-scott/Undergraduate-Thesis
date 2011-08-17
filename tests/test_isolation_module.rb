#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'isolation_module'
require 'drb'
require 'failure_dispatcher'
require 'outage'
require 'outage_correlation'

require 'utilities'
Thread.abort_on_exception = true
$LOG = LoggerLog.new($stderr)

dispatcher = FailureDispatcher.new

hosts = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri).hosts.clone
src = hosts.shift
receivers = hosts[0..5]

if ARGV.empty?
    target = "132.252.152.193"
    srcdst = [src, target]
    outage = Outage.new(src, target, receivers, [], [])
    outage_correlation = OutageCorrelation.new(target, [src], receivers)
    dispatcher.isolate_outages({srcdst => outage},{target => outage_correlation}, true)
else
    src = ARGV.shift
    dst = ARGV.shift
    srcdst = [src, dst]
    dispatcher.isolate_outages({ srcdst => ARGV.map { |str| str.gsub(/,$/, '')  }},
                               {srcdst => []}, {srcdst => []}, true)
end

sleep
