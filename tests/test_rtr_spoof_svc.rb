#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")
##!/usr/bin/ruby -w
require 'drb'
require 'net/http'

$use_db = true
$use_old_reqs = false

$uri_location = "http://revtr.cs.washington.edu/vps/failure_isolation/spoof_only_rtr_module.txt"
uri = Net::HTTP.get_response(URI.parse($uri_location)).body
rtrSvc = DRbObject.new nil, uri

targ = ARGV.shift
$log_probes = false
#$stdout.puts "Found #{pairs.length} pairs to probe!" if pairs.length == 0 then exit end rtrSvc.get_reverse_paths(pairs).each{|k,v| $stdout.puts k.to_s + "=>" + v.to_s }
$stdout.puts rtrSvc.get_reverse_paths([["planet3.prakinf.tu-ilmenau.de", targ],["planet3.upc.es", targ]]).inspect
