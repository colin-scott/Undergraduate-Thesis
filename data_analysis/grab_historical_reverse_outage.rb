#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'
require 'yaml'
require 'failure_analyzer'

LogIterator::iterate do  |outage|
    puts outage.direction.inspect
end
