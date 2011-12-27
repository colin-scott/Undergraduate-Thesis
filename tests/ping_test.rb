#! /usr/bin/ruby

require 'drb'
def calculate_ping_timeout(numtargs)
	# figure 30 parallel threads, max time for 1 is 2 seconds
	(numtargs.to_f/15.0).round + 5
end

DRb.start_service

controller_uri=`cat ~ethan/timestamp/reverse_traceroute/data/uris/controller.txt 2> /dev/null`
controller = DRbObject.new nil, controller_uri

spoofer2receiver2targets=Hash.new { |hash, key|  hash[key] = Hash.new { |inner_hash, inner_key| inner_hash[inner_key] = [] }}

File.open(ARGV[0],"r"){|f|
	f.each_line{|line|
		receiver=line.chomp("\n").split(" ").at(0)
		spoofers=line.chomp("\n").split("{").at(1).split("}").at(0).split(" ")
		targets=line.chomp("\n").split("}").at(1).split(" ")
		$stderr.puts receiver
		$stderr.puts spoofers.join(" ")
		spoofers.each{|spoofer|
			(spoofer2receiver2targets[spoofer])[receiver] += targets
			$stderr.puts "Current requests for #{spoofer} as #{receiver} are #{spoofer2receiver2targets[spoofer][receiver].join(" ")}"
		}
	}
}

max_length=spoofer2receiver2targets.values.collect{|x| x.length}.flatten.max
$stderr.puts max_length

results,failed_spoofers = controller.issue_command_on_hosts(spoofer2receiver2targets,calculate_ping_timeout(max_length)){|vp, receiver2targets| vp.ping(receiver2targets.values)}

failed_spoofers.each{|f|
	$stderr.puts "Spoofer #{f} failed"
}
