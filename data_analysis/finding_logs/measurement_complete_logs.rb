#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")
$: << File.expand_path("../../")

require 'log_iterator'
require 'log_filterer'
require 'filters'
require 'ip_info'
require 'mkdot'
require 'fileutils'

dot_gen = DotGenerator.new
options = OptsParser.new([Predicates.PassedFilters, Predicates.MeasurementComplete]).parse!.display
ip_info = IpInfo.new

LogIterator.iterate_all_logs(options) do |o|
    # Recompute filters... (we loosened the rules before SIGCOMM)
    SecondLevelFilters.filter!(o, FilterTracker.new(o.src,o.dst,o.connected,o.time), ip_info)
    next unless o.passed?

    jpg = "/homes/network/revtr/www/isolation_graphs/potential_cases/jpgs/#{File.basename(o.file)}.jpg"
    dot_gen.generate_jpg(o,jpg)
end

