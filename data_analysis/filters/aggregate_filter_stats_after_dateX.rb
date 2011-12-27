#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../../")
$: << File.expand_path("../")

require 'log_iterator'
require 'filter_stats'
require 'filters'
require 'time'
require 'data_analysis'

if ARGV.empty?
    $stderr.puts "Usage: #{$0} <Date of first log to consider, in the form YYYY.MM.DD[.HH.MM.SS]>"
    exit
end

time_bound = Time.parse(ARGV.join ' ')

total = 0
num_passed = 0
num_failed = 0
level2num_failed = Hash.new(0)
level2reason2count = Hash.new { |h,k| h[k] = Hash.new(0) }

LogIterator::filter_tracker_iterate(time_bound) do |filter_tracker|
    # Each filter_tracker is a single (src, dst) outage
    # in case the filter_tracker came too early in the first day:
    next if filter_tracker.start_time < time_bound 

    total_records += 1
    if filter_tracker.passed?
        num_passed += 1 
    else
        num_failed += 1

        Filters::Levels.each do |level|
            if filter_tracker.failure_reasons.find { |r| Filters.reason2level(r) == level }
                level2num_failed[level] += 1
                break
            end
        end

        filter_tracker.failure_reasons.each do |reason|
            level = Filters.reason2level(reason)
            level2reason2count[level][reason] += 1
        end
    end
end

puts "=============================="
puts
puts "(src, dst) outages since #{time_bound}"
Stats.print_average("total", total, total)
Stats.print_average("num_passed", num_passed, total)
Stats.print_average("num_failed", num_failed, total)

puts "=============================="
puts
puts "Filter Statistics: " 

Filters::Levels.each do |level|
    puts "------------------------------"
    num_failed_here = level2num_failed[level]
    puts "#{level}. # outages filtered here: #{num_failed_here}"
    puts
    puts "Individual triggers (% of outages filtered here):"
    reason2count = level2reason2count[level]
    reason2count.each do |reason, count|
        print "  "
        Stats.print_average(reason, count, num_failed_here)
    end
end   

puts 

