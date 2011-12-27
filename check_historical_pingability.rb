#!/homes/network/revtr/ruby-upgrade/bin/ruby
#
# Given a list of IP addresses, print whether or not they are historically
# pingable.

input = ARGV.shift
if input.nil?
    $stderr.puts "Usage: #{$0} <input file, one IP per line>"
    exit
end

require 'db_interface'

db = DatabaseInterface.new
ips = IO.read(input).split("\n")
ip2responsive = db.fetch_pingability(ips)
ip2responsive.each do |ip, responsive|
    puts "#{ip} #{responsive.inspect}"
end
