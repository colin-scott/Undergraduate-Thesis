#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'data_analysis'
require 'hops'

total = 0
intra = 0
inter = 0

LogIterator::iterate do  |outage|
    if outage.passed_filters
       total += 1
       if !outage.suspected_failure.nil?
           other_as = outage.anyone_on_as_boundary?
           this_as = outage.suspected_failure.asn

           if other_as
              inter += 1
           else
              intra += 1
           end
       end
    end
end

Stats::print_average("intra", intra, total)
Stats::print_average("inter", inter, total)
