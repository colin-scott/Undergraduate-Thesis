#!/homes/network/revtr/ruby-upgrade/bin/ruby

# Aggregate Filter statistics and display them to stdout. Filters all outages
# before the given date.
#
# You can also call this method from another scripts, passing in a predicate.
# See ./no_poisoners.rb for an example

$: << "/homes/network/revtr/spoofed_traceroute/reverse_traceroute"
$: << "/homes/network/revtr/spoofed_traceroute/reverse_traceroute/data_analysis"

require 'log_iterator'
require 'log_filterer'
require 'data_analysis'
require 'filter_stats'
require 'filters'
require 'set'

all_merged_outages = Set.new

# Takes an optional predicate, which is a block that takes a reference to a
# FilterTracker object, and returns true or false for whether that
# FilterTracker is of interest
def filter_and_aggregate(options)
    total_records = 0
    num_passed = 0
    num_failed = 0
    level2num_failed = Hash.new(0)
    level2reason2count = Hash.new { |h,k| h[k] = Hash.new(0) }
    
    # TODO: merge with display_filter_stats_tracker's iterate loop
    FilterTrackerIterator.iterate(options) do |filter_tracker|
        all_merged_outages |= filter_tracker.merged_outage_ids
        # Each filter_tracker is a single (src, dst) outage
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
    puts "(src, dst) outages since #{options[:time_start]} and before #{options[:time_end]}"
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
    $stderr.puts "Note: invoke with --help to see more options"
    options = OptsParser.new
    
    options[:time_start] = Time.now - 24*60*60
    options.on( '-t', '--time_start TIME',
             "Filter outages before TIME (of the form 'YYYY.MM.DD [HH.MM.SS]'). [default last day]") do |time|
        options[:time_start] = Time.parse time
    end

    options.parse!.display
    filter_and_aggregate(options)
end
