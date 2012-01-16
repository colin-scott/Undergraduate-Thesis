#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require 'isolation_module'
require 'failure_isolation_consts.rb'
require 'failure_analyzer'
require 'failure_dispatcher'
require 'log_iterator'
require 'ip_info'
require 'set'
require 'yaml'
require 'time'

analyzer = FailureAnalyzer.new

src_time_directions = []

start_date = Time.utc(2011, 8, 25)

not_nil_count = 0

LogIterator::iterate_all_logs(`cat finding_logs/logs_after_aug_15th.txt`.split("\n")) do |o|
    if !o.direction.eql? Direction.FALSE_POSITIVE and !o.direction.eql? BackwardsCompatibleDirection::FALSE_POSITIVE
        time = o.time
        next unless time
        next unless FailureIsolation.SpooferTargets.include? o.dst
        next if o.time < start_date
        o.direction = (o.direction.is_a?(String)) ? BackwardsCompatibleDirection.convert_to_new_direction(o.direction) : o.direction

        o.suspected_failures ||= {}
        analyzer.identify_fault_single_outage(o)

        if !o.suspected_failure.nil? 
            src_time_directions << [o.src, o.dst, o.time, o.direction, [o.suspected_failure]] 
        elsif !o.suspected_failures.nil? and o.suspected_failures.include? BackwardsCompatibleDirection::FORWARD
            src_time_directions << [o.src, o.dst, o.time, o.direction, o.suspected_failures[BackwardsCompatibleDirection::FORWARD]] 
        elsif !o.suspected_failures.nil? and o.suspected_failures.include? BackwardsCompatibleDirection::BOTH
            src_time_directions << [o.src, o.dst, o.time, o.direction, o.suspected_failures[BackwardsCompatibleDirection::BOTH]]
        elsif !o.suspected_failures.nil? and Direction.FORWARD.eql? o.suspected_failures.keys.first
            $stderr.puts "yay!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            src_time_directions << [o.src, o.dst, o.time, o.direction, o.suspected_failures.values.flatten]
        elsif !o.suspected_failures.nil? and Direction.FORWARD.symbol.eql? o.suspected_failures.keys.first
            $stderr.puts "yay????????????????????????????????????????????????????????????????????????????????"
            src_time_directions << [o.src, o.dst, o.time, o.direction, o.suspected_failures.values.flatten]
        end
    end
end

$stderr.puts src_time_directions.size
File.open("outage_directionality_and_start_time.bin", "w") { |f| f.print Marshal.dump(src_time_directions) }
$stderr.puts not_nil_count
