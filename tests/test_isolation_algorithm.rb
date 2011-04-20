#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'failure_analyzer'
require 'failure_dispatcher'
require 'log_iterator'
require 'hops'
require 'ip_info'
analyzer = FailureAnalyzer.new(IpInfo.new,FailureDispatcher.new)

$stderr.puts "======   rev 4   ======"
LogIterator::all_filtered_outages_rev4 do |file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, cached_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters|
        puts "jpg: #{file}"
        puts suspected_failure
end

$stderr.puts "======   rev 3   ======"
LogIterator::all_filtered_outages_rev3 do |file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr|
        puts "jpg: #{file}"
        puts analyzer.identify_fault(src, dst, direction, tr, spoofed_tr, historical_tr,
                                      spoofed_revtr, historical_revtr)
end

$stderr.puts "======   rev 2   ======"
LogIterator::all_filtered_outages_rev2 do |file, src, dst, dataset, direction, formatted_connected, formatted_unconnected,
               destination_pingable, pings_towards_src, tr,
               spoofed_tr, historical_tr, historical_trace_timestamp,
               spoofed_revtr, historical_revtr|
        puts "jpg: #{file}"
        puts analyzer.identify_fault(src, dst, direction, tr, spoofed_tr, historical_tr,
                                      spoofed_revtr, historical_revtr)
end

# symmetric outages...
