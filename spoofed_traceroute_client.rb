#! /usr/bin/ruby
# creates a Prober, requests measurements from the controller using the
# Prober, and exits after displaying the results of those measurements
$ID = "$Id: reverse_traceroute_client.rb,v 1.8 2010/08/03 07:32:54 ethan Exp $"
$VERSION = $ID.split(" ").at(2).to_f

if ARGV.empty?
	$stderr.puts("Usage: #{$0} [OPTION]... DESTINATION1 [DESTINATION2]...\nTry `#{$0} --help' for more information.")
	exit
end
require 'prober'
require 'optparse'
require 'resolv'
require 'set'

# Hash will include options parsed by OptionParser.
options = Hash.new

optparse = OptionParser.new do |opts|
	options[:acl] = true
	opts.on( '-A', '--no-acl', 'Disable access control list.  Otherwise, only allows connections from localhost and from the host specified in the controller URI.' ) do
		options[:acl] = false
	end
	options[:controller_uri] = nil
	opts.on( '-cURI', '--controller=URI', "Controller URI (default={fetch from #{Prober::CONTROLLER_INFO}})") do|f|
		  options[:controller_uri] = f
	end
	options[:front] = true
	opts.on( '-F', '--no-front', 'Do not front the prober with DRb.' ) do
		options[:front] = false
	end
	opts.on( '-h', '--help', 'Display this screen' ) do
		puts("Usage: #{$0} [OPTION]... DESTINATION1 [DESTINATION2]...")
		puts opts.to_s.split("\n")[1..-1].join("\n")
		exit
	end
	options[:output_dir] = Prober::DEFAULT_TMP_OUTPUT_DIR
	opts.on( '-oPATH', '--out=PATH', "Temp output path PATH (default=#{Prober::DEFAULT_TMP_OUTPUT_DIR})") do|f|
		  options[:output_dir] = f
	end
	options[:port] = Prober::DEFAULT_PORT
	opts.on( '-pPORT', '--port=PORT', Integer, "Port for RPC calls (default=#{Prober::DEFAULT_PORT})") do|i|
		  options[:port] = i
	end

	options[:proberoute_dir] = Prober::DEFAULT_PROBEROUTE_DIR
	opts.on( '-tPATH', '--tools=PATH', "Probe tool path PATH (default=#{Prober::DEFAULT_PROBEROUTE_DIR})") do|f|
		  options[:proberoute_dir] = f
	end
	opts.on( '-v', '--version', 'Version') do
		puts $ID
		puts Prober::PROBER_ID
		exit
	end
end

# parse! parses ARGV and removes any options found there, as well as params to
# the options
optparse.parse!
if options[:controller_uri].nil?
	options[:controller_uri] = Prober::get_default_controller_uri
end

dsts=ARGV
vp=Prober.new(options[:proberoute_dir],options[:output_dir])
Signal.trap("INT"){ vp.shutdown(2) }
Signal.trap("TERM"){ vp.shutdown(15) }
Signal.trap("KILL"){ vp.shutdown(9) }

acl=nil
if options[:acl] 
	acl=Prober::build_acl(options[:controller_uri])
end

vp.start_service(acl, options[:front], options[:port])

puts "Measuring path(s) to #{dsts.join(",")}"
controller = DRbObject.new nil, options[:controller_uri] 

dst2display={}
dsts.each{|dst|
	begin
		dst_ip=Resolv.getaddress(dst)
		dst2display[dst_ip]= ((dst_ip==dst) ? "#{Resolv.getname(dst) rescue ""} (#{dst})" : "#{dst} (#{dst_ip})")
	rescue Exception
		$stderr.puts "Unable to resolve #{dst}: #{$!}"
	end
}

# controller takes only IP addresses, not dns names
dsts = dst2display.keys

dst2sortedttltargettuples = controller.client_spoofed_traceroute(vp,dsts)

dst2sortedttltargettuples.each do |dst, ttltargettuples|
	puts "------------------"
	puts "Spoofed traceroute to #{dst2display[dst]}"
	puts ttltargettuples.map { |tuple| tuple.join ' ' }
	puts
end

vp.shutdown
