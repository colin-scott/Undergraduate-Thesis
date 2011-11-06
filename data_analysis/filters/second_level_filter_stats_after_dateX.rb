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
total = 0
reason2count = Hash.new(0)

LogIterator::correlation_iterate do |o, time|
    next if time < time_bound

    total += o.initial_observing.size
    num_passed += o.final_passed.size

    o.final_failed2reasons.values.each do |reason2triggered|
       reason2triggered.each do |reason, triggered|
           reason2count[reason] += 1 if triggered
       end
    end
end

puts "=============================="
puts
puts "Outage since #{time_bound}"
Stats.print_average("total", total, total)
Stats.print_average("num_passed", num_passed, total)
num_failed = total - num_passed
Stats.print_average("num_failed", num_failed, total)

puts 
puts "filter trigger counts (% of failed):"
reason2count.each do |reason, count|
    print "  "
    Stats.print_average(reason, count, num_failed)
end
