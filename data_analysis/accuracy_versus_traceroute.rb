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

we_win = 0
total = 0
we_win_as = 0

# TODO: encapsulate all of these data items into a single object!
LogIterator::iterate do  |file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters|

    next unless passed_filters
    next unless tr.valid?
    
    total += 1

    tr.link_listify!
    spoofed_tr.link_listify!
    historical_tr.link_listify!
    spoofed_revtr.link_listify!
    historical_revtr.link_listify!

    suspected_failure = analyzer.identify_fault(src, dst, direction, tr, spoofed_tr, historical_tr,
                                      spoofed_revtr, historical_revtr)

    tr_suspect = tr.last_non_zero_hop
    if tr_suspect.nil?
        puts tr.inspect
        next
    end

    we_win += 1 unless suspected_failure.adjacent?(tr_suspect.ip)
    we_win_as += 1 if tr_suspect.asn != suspected_failure.asn
end

puts "we_win: #{we_win}"
puts "we_win_as: #{we_win_as}"
puts total
