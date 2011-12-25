#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'

# TODO: encapsulate all of these data items into a single object!
LogIterator::iterate do  |filename, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters|
       date = LogIterator::parse_time(filename, measurement_times)

       #puts tr.inspect
       #puts spoofed_tr.inspect
       #puts historical_tr.inspect
end
