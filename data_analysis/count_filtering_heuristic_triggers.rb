#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'
require 'time'
require 'data_analysis'
require 'failure_analyzer'
require 'ip_info'

a = FailureAnalyzer.new(IpInfo.new)

LogIterator::iterate do  |o|
    if !o.passed_filters
        a.passes_filtering_heuristics?(o.src, o.dst, o.tr, o.spoofed_tr, o.ping_responsive, o.historical_tr, o.historical_revtr, o.direction, false)
    end
end
