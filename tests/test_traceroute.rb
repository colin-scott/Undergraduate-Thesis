#!/homes/network/revtr/ruby/bin/ruby

require 'isolation_module'
require '../spooftr_config.rb'

controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)

vps = controller.hosts.clone

if !vps.empty?
    curr_vp = vps[rand(vps.size)]
    
    results = registrar.traceroute(curr_vp, (ARGV.empty?) ? ["74.125.224.48", "128.208.4.244"] : ARGV, true) 

    $stderr.puts "Results: #{results.inspect}"
end
