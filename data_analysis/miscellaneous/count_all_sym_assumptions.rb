#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require 'failure_analyzer'
require 'failure_dispatcher'
require 'log_iterator'
require 'ip_info'
require 'set'

dispatcher = FailureDispatcher.new
ipInfo = IpInfo.new
analyzer = FailureAnalyzer.new(ipInfo,dispatcher)

#hist_out = File.open("historical_sym.out", "w")
#spoof_out = File.open("spoof_sym.out", "w")
#all_out = File.open("all_sym.out", "w")

total = 0

missing_historical = []

output = File.open("../missing_historical.txt", "w")

# TODO: encapsulate all of these data items into a single object!
LogIterator::iterate do  |file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters|
    total += 1

    if !historical_revtr.valid? or historical_revtr.empty?
       missing_historical << file 
    end
end

output.puts missing_historical
output.close

#hist_out.close
#spoof_out.close
#all_out.close

#system "scp historical_sym.out spoof_sym.out all_sym.out cs@toil:~"
