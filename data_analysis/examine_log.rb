#!/homes/network/revtr/ruby/bin/ruby

require 'failure_analyzer'
require 'failure_dispatcher'
require 'log_iterator'
require 'ip_info'
require 'set'

dispatcher = FailureDispatcher.new
ipInfo = IpInfo.new
analyzer = FailureAnalyzer.new(ipInfo,dispatcher)

LogIterator::read_log_rev4(FailureIsolation::IsolationResults+"/"+ARGV.shift) do |file, src, dst, dataset, direction, formatted_connected, 
                                        formatted_unconnected, pings_towards_src,
                                      tr, spoofed_tr,
                                      historical_tr, historical_trace_timestamp,
                                      spoofed_revtr, historical_revtr,
                                      suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                      alternate_paths, measured_working_direction, path_changed,
                                      measurement_times, passed_filters|
     analyzer.passes_filtering_heuristics?(src, dst, tr, spoofed_tr, Set.new, historical_tr, direction, testing)
end
