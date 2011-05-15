#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'

# for bidirectional and reverse path outages, how often are 
# does the spoofed traceroute require no symmetry assumptions?
revtr_worked_0 = Hash.new(0) 
# 1 assumption?
revtr_worked_1 = Hash.new(0) 
# 2 assumptions?
revtr_worked_2 = Hash.new(0)

# TODO: encapsulate all of these data items into a single object!
LogIterator::iterate do  |outage|
    next if !outage.passed_filters

    if outage.direction != Direction::FORWARD and outage.spoofed_revtr.valid?
       revtr_worked_0[outage.direction] += 1 if outage.spoofed_revtr.num_sym_assumptions == 0     
       revtr_worked_1[outage.direction] += 1 if outage.spoofed_revtr.num_sym_assumptions == 1     
       revtr_worked_2[outage.direction] += 1 if outage.spoofed_revtr.num_sym_assumptions == 2     
    end
end

puts revtr_worked_0.inspect
puts revtr_worked_1.inspect
puts revtr_worked_2.inspect
