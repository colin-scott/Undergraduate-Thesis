#! /usr/bin/ruby
require 'drb'

DRb.start_service

controller_uri=`cat ~ethan/timestamp/reverse_traceroute/data/uris/controller.txt 2> /dev/null`
if ARGV.length > 0
	controller_uri=ARGV[0]
end
controller = DRbObject.new nil, controller_uri
controller.restart
