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

time = Time.parse(ARGV.shift)

num_passed = 0
total = 0
reason2count = Hash.new(0)

LogIterator::registration_filter_iterate do |filter_list|
    next if filter_list.time < time

    total += filter_list.size

    filter_list.each do |tracker|
        if tracker.passed?
            num_passed += 1
        else
            tracker.failure_reasons.each do |reason|
                reason2count[reason] += 1 if triggered
            end
        end
    end
end

puts "total: #{total}"
Stats.print_average("num_passed", num_passed, total)
num_failed = total - num_passed
Stats.print_average("num_failed", num_failed, total)

puts "registration filter trigger counts (% of failed):"
reason2count.each do |reason, count|
    print "  "
    Stats.print_average(reason, count, num_failed)
end
