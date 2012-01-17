#!/homes/network/revtr/ruby-upgrade/bin/ruby

$: << "/homes/network/revtr/spoofed_traceroute/reverse_traceroute"
$: << "/homes/network/revtr/spoofed_traceroute/reverse_traceroute/data_analysis"

require 'log_iterator'
require 'log_filterer'
require 'ascii_log_dumper.rb'

options = parse_options()

# TODO: merge with aggregate_filter_tracker's iterate loop
FilterTrackerIterator::iterate(options) do |filter_tracker|
    # Each filter_tracker is a single (src, dst) outage
    if options[:attr]
        puts filter_tracker.send(options[:attr])
    else
        puts filter_tracker.inspect
    end
end

