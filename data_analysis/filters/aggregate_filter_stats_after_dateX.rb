#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../../")
$: << File.expand_path("../")

# Aggregate Filter statistics and display them to stdout. Filters all outages
# before the given date.
#
# You can also call this method from another scripts, passing in a predicate.
# See ./no_poisoners.rb for an example

require 'log_iterator'
require 'filter_stats'
require 'filters'
require 'time'
require 'data_analysis'

def get_time_bound()
    if ARGV.empty?
        time_bound = Time.now - (24 * 60 * 60) 
    else
        time_bound = Time.parse(ARGV.join ' ')
    end
    time_bound
end 

# Takes an optional predicate, which is a block that takes a reference to a
# FilterTracker object, and returns true or false for whether that
# FilterTracker is of interest
def filter_and_aggregate(time_bound=get_time_bound(), predicate=lambda { |tracker| true })
    total_records = 0
    num_passed = 0
    num_failed = 0
    level2num_failed = Hash.new(0)
    level2reason2count = Hash.new { |h,k| h[k] = Hash.new(0) }
    
    LogIterator::filter_tracker_iterate(time_bound) do |filter_tracker|
        # Each filter_tracker is a single (src, dst) outage
        # in case the filter_tracker came too early in the first day:
        next if filter_tracker.first_lvl_filter_time < time_bound 
        next unless predicate.call filter_tracker

        puts filter_tracker.source
    
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
    Stats.print_average("total", total_records, total_records)
    Stats.print_average("num_passed", num_passed, total_records)
    Stats.print_average("num_failed", num_failed, total_records)
    
    puts "=============================="
    puts
    puts "Filter Statistics: " 
    
    Filters::Levels.each do |level|
        puts "------------------------------"
        num_failed_here = level2num_failed[level]
        Stats.print_average("#{level}. # outages triggered for (% of total)", num_failed_here, total_records)
        puts
        puts "Individual triggers (% of outages filtered here):"
        reason2count = level2reason2count[level]
        reason2count.each do |reason, count|
            print "  "
            Stats.print_average(reason, count, num_failed_here)
        end
    end   
    
    puts 
end

if __FILE__ == $0
    #filter_and_aggregate()
    filter_and_aggregate(get_time_bound(), lambda { |tracker| not FailureIsolation::PoisonerNames.include? tracker.source })
end
