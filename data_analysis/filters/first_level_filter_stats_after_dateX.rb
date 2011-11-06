#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../../")
$: << File.expand_path("../")

require 'data_analysis'
require 'time'
require 'log_iterator'
require 'filter_stats'

if ARGV.empty?
    $stderr.puts "Usage: #{$0} <Date of first log to consider>"
    exit
end

time = Time.parse(ARGV.shift)

filtered_log_outages = LogIterator.first_level_filter_stats.find_all { |t| t.time >= time }

total = filtered_log_outages.size

categories = filtered_log_outages.categorize_on_attr(:passed?)
passed = categories[true]
failed = categories[false]

total_passed = passed.size

raise "huh? passed + failed != total" if passed.size + failed.size != total

reason2count = Hash.new(0)

failed.each do |t|
    $stderr.puts t.inspect

    t.failure_reasons.each do |reason, triggered|
        reason2count[reason] += 1 if triggered
    end
end

puts "===================================================="
puts "Outages since #{time}:"
puts
Stats.print_average("total", total, total)
Stats.print_average("total passed", total_passed, total)

puts
puts "filter trigger counts:"
reason2count.each do |reason, count|
    puts "  #{reason} #{count}"
end
