#!/homes/network/revtr/ruby-upgrade/bin/ruby

require_relative 'aggregate_filter_stats'
require_relative '../../log_iterator'

options = OptsParser.new
options.on('-s', '--source-filtered',
           "Set pre-defined predicate for examining sources which weren't registered") do |t|
    options[:lambda_string] = "'lambda { |tracker| tracker.failure_reasons.include? RegistrationFilters::SRC_NOT_REGISTERED }'"
    options[:predicate] = lambda { |tracker| tracker.failure_reasons.include? RegistrationFilters::SRC_NOT_REGISTERED }
end

options.on('-a', '--display_attribute ATTR',
           "Rather than displaying the whole tracker, only show the given attribute") do |attr_name|
    options[:attr] = attr_name
end

options.on('-P', '--passed',
           "Set pre-defined predicate for examining outages which passed filters") do |t|
    options[:lambda_string] = "'lambda { |tracker| tracker.passed? }'"
    options[:predicate] = lambda { |tracker| tracker.passed? }
end

options.parse!.display

LogIterator::filter_tracker_iterate(options[:time_start]) do |filter_tracker|
    # Each filter_tracker is a single (src, dst) outage
    next if filter_tracker.first_lvl_filter_time < options[:time_start]
    next if filter_tracker.first_lvl_filter_time > options[:time_end]
    next unless options[:predicate].call filter_tracker

    if options[:attr]
        puts filter_tracker.send(options[:attr])
    else
        puts filter_tracker.inspect
    end
end
