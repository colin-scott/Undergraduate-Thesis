#!/homes/network/revtr/ruby-upgrade/bin/ruby

require_relative '../log_iterator'
require_relative '../log_filterer'
require_relative '../acsii_log_displayer.rb'

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

