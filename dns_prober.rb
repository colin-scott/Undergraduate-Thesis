#!/usr/bin/ruby

require 'resolv'
require 'net/http'
require 'yaml'

class CfProber
 # probe_interval is time to sleep between rounds (in seconds)
 # additional_addrs is the an array of IPs (strings) to use for application-layer pinging
 def initialize(probe_interval=15, additional_addrs=[])
   @probe_interval = probe_interval
   @cf_target = "d1smfj0g31qzek.cloudfront.net"
   @done = false
   @additional_addrs = additional_addrs # CF PoP addreses that Colin is pinging
 end

 def start()
   @my_thread = Thread.new do
     while not @done
       do_probe_round()
       sleep @probe_interval
     end
   end
 end

 def stop()
   @done = true
 end

 def do_probe_round()
   addrs = get_addresses()
   $stderr.puts addrs.inspect
   (addrs+@additional_addrs).each{|addr|
     $stderr.puts "GET #{addr} "
     # TODO collect output
     success, text = get_http(addr)
     $stderr.puts "#{success} #{text}"
   }
 end

 def get_addresses(target=@cf_target)
   return Resolv::getaddresses(target)
 end

 def get_http(address, referer=nil)
   begin
     http = Net::HTTP.new(address, 80)
     path = "/"
     headers = {}
     if not referer.nil? then headers = {'Referer' => 'http://'+@cf_target+path} end
     resp, data = http.request_post(path, "", headers)
     return true, resp.code.to_s
   rescue Exception => e
     return false, e.to_s
   end
 end
end

if __FILE__ == $0
    prober = CfProber.new
    prober.start
    sleep
end
