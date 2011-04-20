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

total = 0
passed = 0
directions = Hash.new(0)
forward_measured_working = Hash.new(0)

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
    if passed_filters
        passed += 1
        directions[direction] += 1

        if direction == Direction::FORWARD and spoofed_revtr.valid?
            forward_measured_working[spoofed_revtr.num_sym_assumptions] += 1
        elsif direction == Direction::FORWARD
            forward_measured_working["spoofed revtr missing"] += 1  
        end
    end
end

puts "total: #{total}"
puts "passed: #{passed}"
puts "directions: #{directions.inspect}"
puts "forward measured working: #{forward_measured_working.inspect}"

#hist_out.close
#spoof_out.close
#all_out.close

#system "scp historical_sym.out spoof_sym.out all_sym.out cs@toil:~"
