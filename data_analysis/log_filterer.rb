
$: << "/homes/network/revtr/spoofed_traceroute/reverse_traceroute"

require 'failure_isolation_consts.rb'
require 'optparse'
require 'forwardable'
require 'time'

module Predicates
    # Commonly used predicates
    
    # We store them as strings so that we can print a human readable display
    # of what the filters are. We later eval them to get the lambda itself.
    
    # ============================================= #
    #       For both filter logs and outage logs    # 
    # ============================================= #

    def self.NOP
        self.hash "lambda { |outage| true }"
    end

    def self.NoPoisoners
        self.hash "lambda { |log| not FailureIsolation::PoisonerNames.include? log.src }"  
    end

    def self.PassedFilters
        self.hash "lambda { |log| log.passed? }"
    end

    def self.TriggeredFilter(trigger_sym)
        self.hash "lambda { |log| log.failure_reasons.include? #{trigger_sym} }"
    end

    def self.PL_PL()
        self.hash "lambda { |log| FailureIsolation.SpooferTargets.include? log.dst }"
    end

    # ============================================= #
    #        Specific to Outage Logs                #
    # ============================================= #

    def self.ValidHistoricalRevtr
        self.hash "lambda { |outage| outage.historical_revtr.valid? }"
    end

    def self.ValidHistoricalTr
        self.hash "lambda { |outage| outage.historical_tr.valid? }"
    end
    
    def self.ValidSpoofedTr
        self.hash "lambda { |outage| outage.spoofed_tr.valid? }"
    end

    def self.ValidTr
        self.hash "lambda { |outage| outage.tr.valid? }"
    end

    def self.MeasurementComplete
        hash = {}
        [self.ValidHistoricalTr, self.ValidHistoricalRevtr, self.ValidSpoofedTr, self.ValidTr].each do |h|
            hash.merge! h 
        end
        hash.merge! self.hash "lambda { |outage| !(outage.direction == Direction.FORWARD && !outage.revtr.valid?) }"
        hash
    end

    def self.Direction(direction)
        self.hash "lambda { |outage| outage.direction == #{direction} }"
    end

    def self.MeasuredWorkingDirection
        self.hash "lambda { |outage| outage.measured_working_direction }"
    end

    def self.Category(category)
        self.hash "lambda { |outage| outage.category == #{category} }"
    end

    # Helper method
    def self.hash(predicate_str)
        { predicate_str => eval(predicate_str) }
    end
end

# TODO: OptsParser is a bad name
class OptsParser
    extend Forwardable
    def_delegators :@options, :[], :[]=
    def_delegators :@options_parser, :on

    # Note: To add more option definitions, make additional invocations to
    # on() before invoking parse!
    def initialize(predicates=[])
        @options = {}
        @options_parser = OptionParser.new("Usage: #{$0} [options] (make sure to wrap all options in quotes)") do |opts|
            @options[:time_start] = Time.at(0)
            opts.on( '-t', '--time_start TIME',
                       "Filter outages before TIME (of the form 'YYYY.MM.DD [HH.MM.SS]'). [default 1970]") do |time|
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
            @options[:predicates] = Predicates.NOP
            opts.on('-p', '--predicate LAMBDA',
                       "Only consider logs where LAMBDA returns true. Invokes eval on given arg. [default: #{@options[:predicates].keys.first}]") do |filter|
                @options[:predicates][filter] = eval(filter)
            end

            opts.on('-n', '--no-poisoners', "Exclude poisoners") do |t|
                @options[:predicates].merge!(Predicates.NoPoisoners)
            end

            @options[:predicate_miss_counts] = Hash.new(0)
        end

        set_predicates!(predicates)
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

    def set_predicates!(predicates)
        predicates.each { |predicate| @options[:predicates].merge!(predicate) }
    end

    def within_time_bound?(log)
        log.time >= @options[:time_start] && log.time <= @options[:time_end]
    end

    def passes_predicates?(log)
        #if log.dst.nil?
        #    $stderr.puts log.class
        #    $stderr.puts log.instance_variables.sort.inspect
        #end
        #if not self.within_time_bound?(log)
        #    @options[:predicate_miss_counts][:time_bound] += 1
        #    return false
        #end

        @options[:predicates].each do |string, predicate|
           if not predicate.call log
                @options[:predicate_miss_counts][string] += 1 
                return false
           end
        end
        @options[:predicate_miss_counts][:passed] += 1
        return true
    end
end

