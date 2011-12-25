#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'
require 'outage'
require 'data_analysis'

require 'failure_analyzer'
total = 0
uni = 0
success = 0

LogIterator::iterate do  |o|
       total += 1
       if o.passed_filters
           if o.direction == Direction::FORWARD
               uni += 1 
               success += 1 if o.spoofed_revtr.successful?
           elsif o.direction == Direction::REVERSE
               uni += 1 
               success += 1 
           end
       end
end

puts total
puts uni
puts success
