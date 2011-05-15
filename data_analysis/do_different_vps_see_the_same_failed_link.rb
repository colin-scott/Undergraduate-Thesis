#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'
require 'time'
require 'data_analysis'

# the value will be... the suspected failed router
# 
# I want to take all [dst, time] tuples,
# and bucket by time.
# say, 20 minutes

dsttime2failure = {}

# TODO: encapsulate all of these data items into a single object!
LogIterator::iterate do |filename, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters|
       next unless passed_filters
       time = LogIterator::parse_time(filename, measurement_times)
       next unless time.is_a?(Time)
       next if suspected_failure.nil?

       dsttime2failure[[dst,time]] = suspected_failure
end

sorted_dsttimes = dsttime2failure.keys.sort_by { |x| x[1] }

first_time = sorted_dsttimes[0][1]
next_time = first_time + 60*20

bucketdsttime2failure = Hash.new(Array.new)

while !sorted_dsttimes.empty?
    puts first_time
    while !sorted_dsttimes.empty? && sorted_dsttimes[0][1] < next_time
        dst, time = sorted_dsttimes.shift 
    
        bucketdsttime2failure[dst,first_time] = [] unless bucketdsttime2failure.include? [dst, first_time]
        bucketdsttime2failure[[dst,first_time]] << dsttime2failure[[dst,time]]
    end
    first_time = next_time
    next_time += 60*20
end

bucketdsttime2failure.each do |dsttime, failures|
    if failures.size > 1
        puts "dsttime: #{dsttime.inspect} num failures: #{failures.size}, uniq failures: #{failures.uniq.size}"
    end
end


