#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'
require 'outage'
require 'data_analysis'

total = 0
total_missed = 0

# TODO: encapsulate all of these data items into a single object!
LogIterator::iterate do  |outage|
       total += 1
       total_missed += 1 if outage.ping_responsive.include? outage.dst || outage.tr.reached?(outage.dst)

       #puts tr.inspect
       #puts spoofed_tr.inspect
       #puts historical_tr.inspect
end

Stats::print_average("missed", total_missed, total)
