#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../../")
$: << File.expand_path("../")

require 'log_iterator'
require 'filter_stats'
require 'time'
require 'data_analysis'

if ARGV.empty?
    $stderr.puts "Usage: #{$0} <Date of first log to consider, in the form YYYY.MM.DD[.HH.MM.SS]>"
    exit
end

time_bound = Time.parse(ARGV.join ' ')

num_passed = 0
total_nodes = 0
total_records = 0
reason2count = Hash.new(0)

LogIterator::second_lvl_filter_iterate(time_bound) do |filter_stats|
    next if filter_stats.start_time < time_bound # not strictly necessary...

    total_records += 1 unless filter_stats.initial_observing.empty?
    total_nodes += filter_stats.initial_observing.size
    num_passed += filter_stats.final_passed.size

    # TODO: o.final_passed.size doesn't match up with
    # o.final_failed2reasons.size! (and total...)
    raise "failed doesn't match total #{filter_stats}" if (total_nodes - num_passed) != filter_stats.final_failed2reasons.size

    filter_stats.final_failed2reasons.values.each do |reason2triggered|
       # These are per-node failure reasons...
       puts "reason2triggered: #{reason2triggered}"
       reason2triggered.each do |reason, triggered|
           reason2count[reason] += 1 if triggered
       end
    end
end

puts "=============================="
puts
puts "#{total_records} outages since #{time_bound}"
Stats.print_average("total_nodes", total_nodes, total_nodes)
Stats.print_average("num_passed", num_passed, total_nodes)
num_failed = total_nodes - num_passed
Stats.print_average("num_failed", num_failed, total_nodes)

puts 
puts "filter trigger counts (% of failed):"
reason2count.each do |reason, count|
    print "  "
    Stats.print_average(reason, count, num_failed)
end
