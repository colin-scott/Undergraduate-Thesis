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
require 'optparse'
require 'forwardable'

class OptsParser
    extend Forwardable
    def_delegators :@options, :[], :[]=
    def_delegators :@options_parser, :on

    # Note: To add more option definitions, make additional invocations to
    # on() before invoking parse!
    def initialize()
        @options = {}
        @options_parser = OptionParser.new("Usage: #{$0} [options] (make sure to wrap all options in quotes)") do |opts|
            @options[:time_start] = Time.now - (24 * 60 * 60)
            opts.on( '-t', '--time_start TIME',
                       "Filter outages before TIME (of the form 'YYYY.MM.DD [HH.MM.SS]'). [default last 24 hours]") do |time|
                @options[:time_start] = Time.parse time
            end
    
            @options[:time_end] = Time.now
            opts.on( '-e', '--time_end TIME',
                       "Filter outages after TIME (of the form 'YYYY.MM.DD [HH.MM.SS]'). [default now]") do |time|
                @options[:time_end] = Time.parse time
            end
    
            # Hash from human readable lamda -> predicate
            # TODO: don't foce them to type 'lambda { |tracker|'   -- just
            # have them specify the boolean function that goes inside
            @options[:predicates] = { "'lambda { |tracker| true }'" =>  lambda { |tracker| true } }
            opts.on('-p', '--predicate LAMBDA',
                       "Only consider stats trackers LAMBDA returns true. Invokes eval on given arg. [default: #{@options[:lambda_string]}]") do |filter|
                @options[:predicates] = { "'#{filter}'" => eval(filter) }
            end
    
            opts.on('-n', '--no-poisoners',
                       "Set pre-defined predicate for exluding BGP Mux nodes") do |t|
                @options[:predicates][ "'lambda { |tracker| not FailureIsolation::PoisonerNames.include? tracker.source }'"] = \
                                         lambda { |tracker| not FailureIsolation::PoisonerNames.include? tracker.source }
            end
        end
    end

    def parse!()
        @options_parser.parse!
        self
    end

    def display()
       $stderr.puts "Filtering outages before #{@options[:time_start]}"
       $stderr.puts "Filtering outages after  #{@options[:time_end]}"
       $stderr.puts "Applying predicates:"
       @options[:predicates].each do |name, predicate|
            $stderr.puts "       #{name}"
       end
       self
    end

    def passes_predicates?(filter_tracker)
        @options[:predicates].each do |string, predicate|
           return false unless predicate.call filter_tracker
        end
        return true
    end
end

# Takes an optional predicate, which is a block that takes a reference to a
# FilterTracker object, and returns true or false for whether that
# FilterTracker is of interest
def filter_and_aggregate(options)
    total_records = 0
    num_passed = 0
    num_failed = 0
    level2num_failed = Hash.new(0)
    level2reason2count = Hash.new { |h,k| h[k] = Hash.new(0) }
    
    FilterTrackerIterator.iterate(options[:time_start]) do |filter_tracker|
        # Each filter_tracker is a single (src, dst) outage
        next if filter_tracker.first_lvl_filter_time < options[:time_start]
        next if filter_tracker.first_lvl_filter_time > options[:time_end]
        next unless options.passes_predicates?(filter_tracker)

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
    options = OptsParser.new.parse!.display
    filter_and_aggregate(options)
end
