#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

# $TEST = true

require 'isolation_module'
require 'drb'
require 'failure_dispatcher'
require 'outage'

require 'isolation_utilities'
Thread.abort_on_exception = true

uri = ARGV.shift
uri ||= FailureIsolation::ControllerUri

dispatcher = FailureDispatcher.new()
hosts = DRb::DRbObject.new_with_uri(uri).hosts.sort_by { rand }.clone.find_all { |h| h.include? "bgpmux" } - ["prin.bgpmux"]

src = hosts.shift
receivers = hosts[0..5]

if ARGV.empty?
    target = "132.252.152.193"
    srcdst = [src, target]
    outage = Outage.new(src, target, receivers, [], [], [])
    outage_correlation = OutageCorrelation.new(target, [src], receivers)
    dispatcher.isolate_outages({srcdst => outage},{target => outage_correlation})
else
    src = ARGV.shift
    dst = ARGV.shift
    srcdst = [src, dst]
    dispatcher.isolate_outages({ srcdst => ARGV.map { |str| str.gsub(/,$/, '')  }},
                               {srcdst => []}, {srcdst => []})
end

sleep
