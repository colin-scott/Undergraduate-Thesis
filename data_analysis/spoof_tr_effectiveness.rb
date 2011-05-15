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

spoof_difference = []
filtered_spoof_difference = []

# TODO: encapsulate all of these data items into a single object!
LogIterator::iterate do  |file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters|

    next if spoofed_tr.empty? or tr.empty?
    difference = spoofed_tr.without_zeros.size - tr.without_zeros.size
    spoof_difference << difference
    if passed_filters
        filtered_spoof_difference << difference
    end 
end

spoof_difference.sort!
filtered_spoof_difference.sort!

File.open("spoof_difference.dat", "w") { |f| f.puts spoof_difference }
File.open("filtered_spoof_difference.dat", "w") { |f| f.puts filtered_spoof_difference }

system "scp spoof_difference.dat filtered_spoof_difference.dat cs@toil:~/thesis_data/spoof_tr_effectiveness"
