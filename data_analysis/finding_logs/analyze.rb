#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../../")


require 'isolation_module'
require 'utilities'
require 'failure_analyzer'
require 'failure_dispatcher'
require 'log_iterator'
require 'ip_info'
require 'set'

date = Time.utc(2011, 8, 25)

total = 0

LogIterator::merged_iterate do |m|
    next unless !m.is_interesting?
    next unless m.direction == Direction.REVERSE

    next if !m.time
    next if m.time < date

    total += 1
    puts "#{FailureIsolation::MergedIsolationResults}/#{m.file}.bin"
end


puts total
