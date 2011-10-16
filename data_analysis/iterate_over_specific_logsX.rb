#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'

input_logs = IO.read(ARGV.shift).split("\n").map { |f| "#{f}.bin" }

LogIterator::iterate(input_logs) do |outage|
    puts outage.file
end
