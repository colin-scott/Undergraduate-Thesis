#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << "../"

require 'drb'
require 'isolation_module'
require 'failure_analyzer'
require 'failure_dispatcher'

uri = ARGV.shift

controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)

dispatcher = FailureDispatcher.new

i = 0

vps = controller.hosts.clone.delete_if { |h| h =~ /bgpmux/i }

if !vps.empty?
    i = (i + 1) % vps.size

    curr_vp = (ARGV.empty?) ? vps[i] : ARGV.shift
    targets = (ARGV.empty?) ? ["128.208.3.88"] : [ARGV.shift]
    puts "curr_vp: #{curr_vp}"
    vps.delete(curr_vp)

    vps = (ARGV.empty?) ? vps : ARGV
    
    dst2ttlrtrs= registrar.batch_spoofed_traceroute({[curr_vp, targets.first] => vps})
    puts dst2ttlrtrs
end
