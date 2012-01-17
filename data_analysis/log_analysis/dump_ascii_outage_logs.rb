#!/homes/network/revtr/ruby-upgrade/bin/ruby

require_relative 'analyze_outage_logs'
require_relative '../log_iterator'

$stderr.puts "Note: invoke with --help to see more options"

options = OptsParser.new
options.on('-f', '--filter FILTER',
           "Only consider outages where the given filter was triggered. FILTER is one of the names from aggregate_filter_stats.rb") do |filter|
    filter = filter.to_sym
    predicate_str = "lambda { |outage| outage.failure_reasons.include? #{filter.inspect} }"
    options[:predicates][predicate_str] = eval(predicate_str)
end

options.on('-a', '--display_attribute ATTR',
           "Rather than displaying the whole outage, only show the given attribute (e.g. 'src')") do |attr_name|
    options[:attr] = attr_name
end

options.on('-P', '--passed',
           "Set pre-defined predicate for examining outages which passed filters") do |t|
    predicate_str = "lambda { |outage| outage.passed? }"
    options[:predicates][predicate_str] = eval(predicate_str)
end

options.parse!.display


