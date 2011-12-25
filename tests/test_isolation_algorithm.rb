#!/homes/network/revtr/ruby-upgrade/bin/ruby

require 'failure_analyzer'
require 'log_iterator'
require 'ip_info'
analyzer = FailureAnalyzer.new(IpInfo.new)

$stderr.puts "======   rev 3   ======"
LogIterator::all_filtered_outages do |file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr|

    if(analyzer.passes_filtering_heuristics(src, dst, tr, spoofed_tr, ["not_empty"], # hmmmm...
                                              historical_tr, direction, false))

        suspect = analyzer.identify_fault(src, dst, direction, tr, spoofed_tr, historical_tr,
                                      spoofed_revtr, historical_revtr)

        puts "==================="
        puts "jpg: #{File.basename(LogIterator::yml2jpg(file))}"
        puts "suspect: #{suspect}"
        LogIterator::display_results(src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr)
    else
        $stderr.puts "Whaaaaaaaaat??????"
    end
end

$stderr.puts "======   rev 2   ======"
LogIterator::all_filtered_outages_rev2 do |file, src, dst, dataset, direction, formatted_connected, formatted_unconnected,
               destination_pingable, pings_towards_src, tr,
               spoofed_tr, historical_tr, historical_trace_timestamp,
               spoofed_revtr, historical_revtr|

    if(analyzer.passes_filtering_heuristics(src, dst, tr, spoofed_tr, ["not_empty"], # hmmmm...
                                              historical_tr, direction, false))

        suspect = analyzer.identify_fault(src, dst, direction, tr, spoofed_tr, historical_tr,
                                      spoofed_revtr, historical_revtr)

        puts "==================="
        puts "jpg: #{File.basename(LogIterator::yml2jpg(file))}"
        puts "suspect: #{suspect}"
        LogIterator::display_results(src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr)

    end
end

