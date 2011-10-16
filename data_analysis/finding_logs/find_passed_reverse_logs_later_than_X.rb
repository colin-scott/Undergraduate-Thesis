#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../../")


require 'isolation_module'
require 'utilities'
require 'failure_analyzer'
require 'failure_dispatcher'
require 'log_iterator'
require 'ip_info'
require 'set'

date = Time.utc(2011, 8, 25)

LogIterator::iterate_all_logs do |o|
    next unless o.passed_filters
    next unless o.direction == Direction.REVERSE

    next if !o.time
    next if o.time < date

    puts "#{FailureIsolation::IsolationResults}/#{o.file}.bin"
end

