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

success = []
LogIterator::iterate do |file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters|
    next unless passed_filters
    next unless direction == Direction::REVERSE 

    if historical_revtr.valid? and !historical_revtr.empty? and historical_revtr.longest_sym_sequence == 1
        puts file
        success << file
    end
end

puts success
