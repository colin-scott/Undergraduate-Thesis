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

total_reverse = 0
without_historical = 0
without_spoofed = 0
neither = 0
num_historical_sym_assumptions = []
num_spoofed_sym_assumptions = []
average_revtr_length = []
average_max_sym_sequence = []

successful = 0

no_historical_files = []

LogIterator::iterate do  |file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters|
    next unless passed_filters
    next unless direction == Direction::REVERSE 

    total_reverse += 1

    no_historical = true
    if historical_revtr.valid? and !historical_revtr.empty?
        no_historical = false
        num_historical_sym_assumptions << historical_revtr.num_sym_assumptions
        average_revtr_length << historical_revtr.length
        longest_sym = historical_revtr.longest_sym_sequence
        average_max_sym_sequence <<  longest_sym
    else
        without_historical += 1
        no_historical_files << file 
    end

    if spoofed_revtr.valid? and !spoofed_revtr.empty?
        num_spoofed_sym_assumptions << spoofed_revtr.num_sym_assumptions
        average_revtr_length << spoofed_revtr.length
        longest_sym = spoofed_revtr.longest_sym_sequence
        average_max_sym_sequence <<  longest_sym
    else 
        neither += 1 if no_historical
        without_spoofed += 1
    end
end

puts "Synopsis!"
puts "total reverse: #{total_reverse}"
puts "without historical revtr: #{without_historical} #{without_historical * 100.0 / total_reverse}%"
puts "without spoofed revtr: #{without_spoofed} #{without_spoofed * 100.0 / total_reverse}%"
puts "without historical and spoofed: #{neither} #{neither * 100.0 / total_reverse}%"
puts "average historical sym assumptions: #{num_historical_sym_assumptions.reduce(:+) * 1.0 / num_historical_sym_assumptions.size}"
puts "average spoofed sym assumptions: #{num_spoofed_sym_assumptions.reduce(:+) * 1.0 / num_spoofed_sym_assumptions.size}"
puts "average reverse path length: #{average_revtr_length.reduce(:+) * 1.0 / average_revtr_length.size}"
puts "average max sym subseqence length: #{average_max_sym_sequence.reduce(:+) * 1.0 / average_max_sym_sequence.size}"
puts no_historical_files
