#!/homes/network/revtr/ruby-upgrade/bin/ruby

require_relative 'aggregate_filter_stats'
require_relative '../log_iterator'

$stderr.puts "Note: invoke with --help to see more options"

options = OptsParser.new
options.on('-f', '--filter FILTER',
           "Only consider outages where the given filter was triggered. FILTER is one of the names from aggregate_filter_stats.rb") do |filter|
    filter = filter.to_sym
    options[:predicates]["'lambda { |tracker| tracker.failure_reasons.include? #{filter.inspect} }'"] =\
                           lambda { |tracker| tracker.failure_reasons.include? filter }
end

options.on('-a', '--display_attribute ATTR',
           "Rather than displaying the whole tracker, only show the given attribute (e.g. 'src')") do |attr_name|
    options[:attr] = attr_name
end

options.on('-P', '--passed',
           "Set pre-defined predicate for examining outages which passed filters") do |t|
    options[:predicates]["'lambda { |tracker| tracker.passed? }'"] =\
                           lambda { |tracker| tracker.passed? }

end

options.parse!.display

LogIterator::filter_tracker_iterate(options[:time_start]) do |filter_tracker|
    # Each filter_tracker is a single (src, dst) outage
    next if filter_tracker.first_lvl_filter_time < options[:time_start]
    next if filter_tracker.first_lvl_filter_time > options[:time_end]
    next unless options.passes_predicates?(filter_tracker)

    if options[:attr]
        puts filter_tracker.send(options[:attr])
    else
        puts filter_tracker.inspect
    end
end
