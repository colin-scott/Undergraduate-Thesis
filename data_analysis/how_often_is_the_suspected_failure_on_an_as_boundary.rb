#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'

total = 0
on_as_boundary = 0

# TODO: encapsulate all of these data items into a single object!
LogIterator::iterate do  |outage|
       next unless outage.passed_filters 

       total += 1
       on_as_boundary += 1 if outage.anyone_on_as_boundary?()
       puts outage.anyone_on_as_boundary?()
end

puts "total: #{total}"
puts "on_as_boundary: #{on_as_boundary} #{on_as_boundary*100.0/total}"
