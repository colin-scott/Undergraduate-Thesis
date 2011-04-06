#!/homes/network/revtr/ruby/bin/ruby

require 'failure_analyzer'
require 'log_iterator'
require 'ip_info'
analyzer = FailureAnalyzer.new(IpInfo.new)

LogIterator::all_filtered_outages do |file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr|

    if(analyzer.passes_filtering_heuristics(src, dst, tr, spoofed_tr, ["not_empty"], # hmmmm...
                                              historical_tr, direction, false))


        suspect = analyzer.identify_fault(src, dst, direction, tr, spoofed_tr, historical_tr,
                                      spoofed_revtr, historical_revtr)

        next if !suspect.nil?

        puts "==================="
        puts "jpg: #{File.basename(LogIterator::yml2jpg(file))}"
        puts "Suspect: #{suspect}"
        LogIterator::display_results(src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr)
    end
end
