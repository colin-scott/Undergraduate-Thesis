#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'isolation_module'
require 'hops'
require 'time'
require 'data_analysis'

count = 0
total = 0

LogIterator::iterate() do |o|
    total += 1
    count += 1 if FailureIsolation::SpooferTargets.include? o.dst 
end

puts count
puts total
