#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'
require 'time'
require 'data_analysis'

times = Hash.new(Average.new)

total = 0 

avg_total_time = Average.new

# TODO: encapsulate all of these data items into a single object!
LogIterator::iterate do  |filename, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters|
    next if measurement_times.empty?

    avg_total_time.fold_in(MeasurementTimes.new(measurement_times).total_duration_seconds)

    measurement_times[0..-2].each do |x| 
        times[x[0]] = Average.new unless times.include?(x[0])
        times[x[0]].fold_in(x[2][1..(x[2].index(' '))].to_i) 
    end

    total += 1

    if (total % 100) == 0
        times.each do |k,v|
            puts "#{k} #{v.avg}"
        end
    end
end

puts avg_total_time.inspect
puts avg_total_time.avg
