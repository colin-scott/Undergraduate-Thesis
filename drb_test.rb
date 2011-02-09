#!/usr/bin/ruby -w

require 'drb'
require 'drb/acl'
require 'net/http'
require '../spooftr_config'

uri_location = "http://revtr.cs.washington.edu/vps/failure_isolation/spoof_only_rtr_module.txt"
uri = Net::HTTP.get_response(URI.parse(uri_location)).body
rtrSvc = DRbObject.new nil, uri
srcdst = (ARGV.empty?) ? [["planetlab-node3.it-sudparis.eu", "87.236.232.153"]] : [[ARGV.shift, ARGV.shift]]
begin
    puts rtrSvc.get_reverse_paths(srcdst)
rescue DRb::DRbConnError => e
    puts "Caught exception #{e}!"
end

