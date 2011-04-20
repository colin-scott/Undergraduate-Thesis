#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'failure_analyzer'
require 'failure_dispatcher'
require 'log_iterator'
require 'ip_info'
require 'set'

dispatcher = FailureDispatcher.new
ipInfo = IpInfo.new
analyzer = FailureAnalyzer.new(ipInfo,dispatcher)

LogIterator::read_log_rev4("/homes/network/revtr/spoofed_traceroute/data/isolation_results_final/planetlab2.eecs.umich.edu_61.8.142.1_2011416152616.yml") do |file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, cached_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters|

    puts passed_filters
    puts analyzer.passes_filtering_heuristics?(src, dst, tr, spoofed_tr, Set.new(["1.2.3.4"]),
                                               historical_tr, direction, false)

end

