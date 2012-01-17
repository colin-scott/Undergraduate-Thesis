#!/homes/network/revtr/ruby-upgrade/bin/ruby

require_relative '../log_iterator'
require_relative '../log_filterer'
require_relative '../ascii_log_dumper.rb'

options = parse_options()

FilterTrackerIterator::iterate(options[:time_start]) do |filter_tracker|
    # Each filter_tracker is a single (src, dst) outage
    next unless options.passes_predicates?(filter_tracker)

    if options[:attr]
        puts filter_tracker.send(options[:attr])
    else
        puts filter_tracker.inspect
    end
end

