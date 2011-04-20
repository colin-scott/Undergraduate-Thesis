#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'isolation_module'
require '../spooftr_config.rb'

controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)

vps = controller.hosts.clone

i = 0

if !vps.empty?
    curr_vp = (ARGV.empty?) ? vps[i] : ARGV.shift
    targets = (ARGV.empty?) ? ["128.208.3.88"] : ARGV
    puts "curr_vp: #{curr_vp}"
    vps.delete(curr_vp)

    receive_results = registrar.receive_spoofed_pings(curr_vp, targets, vps, true)

    puts "receive_results (target2receiver2succesfulsenders)"
    puts receive_results.inspect
    send_results = registrar.send_spoofed_pings(curr_vp, targets, vps, true)
    puts "send_results (target2receiver2succesfulsenders)"
    puts send_results.inspect
end
