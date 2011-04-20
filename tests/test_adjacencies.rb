#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")
# #! /usr/bin/ruby
configfn="/homes/network/ethan/timestamp/reverse_traceroute/reverse_traceroute/config_zooter.rb"
require configfn
require "reverse_traceroute"
ip="216.253.211.45"
dest="169.226.40.8"
timeout=10

check_adjacencies_thread=Thread.new { 
	loop {
		sleep(600)
		begin
			Timeout::timeout(timeout) do
				adjs=getAdjacenciesForIPtoSrc( ip, dest )
				if adjs.nil? or adjs.length < 1
					# ERROR
				end
			end
		rescue Timeout::Error
			# ERROR
		end
	}
}
check_adjacencies_thread.priority = -10

check_adjacencies_thread.join
