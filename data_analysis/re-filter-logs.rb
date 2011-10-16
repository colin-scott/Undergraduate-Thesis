#!/homes/network/revtr/ruby/bin/ruby

require 'failure_analyzer'
require 'failure_dispatcher'
require 'log_iterator'
require 'ip_info'
require 'set'

dispatcher = FailureDispatcher.new
ipInfo = IpInfo.new
analyzer = FailureAnalyzer.new(ipInfo)

LogIterator::replace_logs(dispatcher) do |o|
    o.passed_filters = analyzer.passes_filtering_heuristics?(o.src, o.dst, o.tr, o.spoofed_tr, o.ping_responsive, o.historical_tr, 
                                             o.historical_revtr, o.direction, false)

    o.tr = o.tr.find_all { |hop| !hop.is_a?(MockHop) }
    o.historical_tr = o.historical_tr.find_all { |hop| !hop.is_a?(MockHop) }
    o.spoofed_tr = o.spoofed_tr.find_all { |hop| !hop.is_a?(MockHop) }

    if o.tr.is_a?(Array)
        o.tr = ForwardPath.new(o.tr)
    end

    if o.historical_tr.is_a?(Array)
        o.historical_tr = ForwardPath.new(o.historical_tr)
    end

    if o.spoofed_tr.is_a?(Array)
        o.spoofed_tr = ForwardPath.new(o.spoofed_tr)
    end

    if o.historical_revtr.is_a?(Array)
        o.historical_revtr = HistoricalReversePath.new(o.historical_revtr)
    end

    if o.spoofed_revtr.is_a?(Array)
        o.spoofed_revtr = SpoofedReversPath.new(o.spoofed_revtr)
    end

    o.suspected_failure = analyzer.identify_fault(o.src, o.dst, o.direction, o.tr, o.spoofed_tr, o.historical_tr,
                                      o.spoofed_revtr, o.historical_revtr)

    o.alternate_paths = analyzer.find_alternate_paths(o.src, o.dst, o.direction, o.tr, o.spoofed_tr, o.historical_tr,
                                      o.spoofed_revtr, o.historical_revtr)

    o.category = analyzer.categorize_failure(o)

    o
end
