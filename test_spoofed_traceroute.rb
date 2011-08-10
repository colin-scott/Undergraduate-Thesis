#!/homes/network/revtr/ruby/bin/ruby

require 'drb'
require 'isolation_module'
require '../spooftr_config.rb'

controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)

i = 0

vps = controller.hosts.clone

if !vps.empty?
    i = (i + 1) % vps.size

    curr_vp = (ARGV.empty?) ? vps[i] : ARGV.shift
    targets = (ARGV.empty?) ? ["128.208.3.88"] : [ARGV.shift]
    puts "curr_vp: #{curr_vp}"
    vps.delete(curr_vp)

    vps = (ARGV.empty?) ? vps : ARGV

    dest2ttltargettuple = registrar.client_spoofed_traceroute(curr_vp, targets, vps, true)
    puts dest2ttltargettuple.inspect
end
