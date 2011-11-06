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

time = Time.parse(ARGV.join ' ')

num_passed = 0
total = 0
reason2count = Hash.new(0)
vp2fail_count = Hash.new(0)

LogIterator::registration_filter_iterate do |filter_list|
    next if filter_list.time < time

    filter_list.each do |tracker|
        total += 1

        if tracker.passed?
            num_passed += 1
        else
            tracker.failure_reasons.each do |reason|
                reason2count[reason] += 1
            end

            vp2fail_count[tracker.outage.src] += 1
        end
    end
end

puts "=================================================="
puts 
puts "Outages since #{time}"
Stats.print_average("total", total, total)
Stats.print_average("num_passed", num_passed, total)
num_failed = total - num_passed
Stats.print_average("num_failed", num_failed, total)

puts 
puts "registration filter trigger counts (% of failed):"
reason2count.each do |reason, count|
    print "  "
    Stats.print_average(reason, count, num_failed)
end

puts
puts "per VP trigger counts:"
vp2fail_count.each do |vp, count|
    print "  "
    puts "#{vp} #{count}"
end
