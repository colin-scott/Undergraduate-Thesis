#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'

LogIterator::iterate() do |outage|
    puts outage.file
end
