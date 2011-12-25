#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'isolation_module'
require 'mkdot'

# src -> [booleans of whether the forward traceroute was empty]
failed_traceroutes = Hash.new { |h, k| h[k] = [] }

LogIterator::iterate() do |file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, cached_revtr|
    failed_traceroutes[src] << tr.empty?
end

failed_traceroutes.each do |src, bools|
    failed_count = bools.reduce(0) { |memo, obj| (obj) ? memo + 1 : memo }
    puts "#{src} #{failed_count} #{bools.size} #{failed_count * 100.0 / bools.size }"
end
