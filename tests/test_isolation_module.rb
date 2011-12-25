#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'isolation_module'
require 'drb'
require 'failure_dispatcher'
require 'outage'
require 'outage_correlation'

require 'utilities'
Thread.abort_on_exception = true

dispatcher = FailureDispatcher.new()

hosts = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri).hosts.sort_by { rand }.clone
src = hosts.shift
receivers = hosts[0..5]

if ARGV.empty?
    target = "132.252.152.193"
    srcdst = [src, target]
    outage = Outage.new(src, target, receivers, [], [], [])
    filter_tracker = FilterTracker.new(src, target, receivers, Time.new)
    dispatcher.isolate_outages({srcdst => outage},{srcdst => filter_tracker}, true)
else
    src = ARGV.shift
    dst = ARGV.shift
    srcdst = [src, dst]
    outage = Outage.new(src, target, receivers, [], [], [])
    filter_tracker = FilterTracker.new(src, target, receivers, Time.new)
    dispatcher.isolate_outages({srcdst => outage},{srcdst => failure_tracker}, true)
end

sleep
