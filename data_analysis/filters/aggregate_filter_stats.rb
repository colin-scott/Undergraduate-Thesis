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


# Takes an optional predicate, which is a block that takes a reference to a
# FilterTracker object, and returns true or false for whether that
# FilterTracker is of interest
def filter_and_aggregate(options)
    all_merged_outages = Set.new

    total_records = 0
    num_passed = 0
    num_failed = 0
    level2num_failed = Hash.new(0)
    level2reason2count = Hash.new { |h,k| h[k] = Hash.new(0) }
    
    # TODO: merge with display_filter_stats_tracker's iterate loop
    FilterTrackerIterator.iterate(options) do |filter_tracker|
        all_merged_outages |= filter_tracker.merged_outage_ids if filter_tracker.merged_outage_ids

        # Each filter_tracker is a single (src, dst) outage
        total_records += 1
        if filter_tracker.passed?
            num_passed += 1 
        else
            num_failed += 1
    
            # Assumes that Levels are applied in increasing order
            last_filter_level = nil
            Filters::Levels.each do |current_level|
                # Skip over any outages which were filtered the round before
                # (to accomodate overlapping filters)
                next if last_filter_level and filter_tracker.failure_reasons.find { |r| Filters.reason2level(r) == last_filter_level }

                if filter_tracker.failure_reasons.find { |r| Filters.reason2level(r) == current_level }
                    level2num_failed[current_level] += 1

                    filter_tracker.failure_reasons.each do |reason|
                        reason_level = Filters.reason2level(reason)
                        next if reason_level != current_level
                        level2reason2count[reason_level][reason] += 1
                    end                                             
                end

                last_filter_level = current_level
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

    # Should be equivalent to: all_filters.find_all { |f| f.passed? }.map { |f| f.merged_outage_ids }.uniq
    num_merged_passed = 0
    # Now, check how many of the merged outages passed filters
    all_merged_outages.delete nil
    MergedLogIterator.iterate_over_files(options, all_merged_outages) do |merged_outage|
        num_merged_passed += 1 if merged_outage.passed?
    end

    puts "=============================="
    puts
    puts "Number of merged outages passing filters:"
    Stats.print_average("total", all_merged_outages.size, all_merged_outages.size)
    Stats.print_average("num_passed", num_merged_passed, all_merged_outages.size)
    Stats.print_average("num_failed", all_merged_outages.size - num_merged_passed, all_merged_outages.size)
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
