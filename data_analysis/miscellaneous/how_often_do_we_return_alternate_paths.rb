#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'
require 'data_analysis'
require 'ip_info'
require 'failure_dispatcher'
require 'failure_analyzer'

analyzer = FailureAnalyzer.new(IpInfo.new, FailureDispatcher.new)

total = 0
passed = 0
alternate = 0
alternate_passed = 0

alternates = Hash.new(0)

# TODO: encapsulate all of these data items into a single object!
LogIterator::iterate(true) do  |outage|
       total += 1
       passed += 1 if outage.passed_filters
       alternate += 1 if !outage.alternate_paths.empty?
       alternate_passed += 1 if !outage.alternate_paths.empty? and outage.passed_filters

       outage.alternate_paths.each do |sym|
           alternates[sym] += 1
       end

       #directions[direction] += 1 if !alternate_paths
       #directions[direction] = Average.new unless directions.include?(direction)

       #if passed_filters
       #   
       #   val = (alternate_paths.empty?) ? 0 : 1  
       #   directions[direction].fold_in(val)
       #end

       #puts tr.inspect
       #puts spoofed_tr.inspect
       #puts historical_tr.inspect
end

puts "total: #{total}"
puts "passed: #{passed}"
puts "alternate: #{alternate} #{alternate*1.0/total}"
puts alternates.inspect
