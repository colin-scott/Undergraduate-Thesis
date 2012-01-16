#!/usr/bin/ruby
$: << File.expand_path("../")
$: << File.expand_path("../")

file = ARGV.shift
input = File.open(file)
output = File.open("buf", "w")

line = input.gets
output.print line
output.puts '$: << File.expand_path("../")'

while line = input.gets
    output.print line
end

output.close

`mv buf #{file}`
