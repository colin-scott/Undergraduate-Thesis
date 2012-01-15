#!/homes/network/revtr/ruby-upgrade/bin/ruby

require 'isolation_module'
require '../spooftr_config.rb'

controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)

vps = controller.hosts.clone

if !vps.empty?
    curr_vp = vps[rand(vps.size)]
    
    results = registrar.ping(curr_vp, (ARGV.empty?) ? ["74.125.224.48", "128.208.4.244"] : ARGV, true) 

    $stderr.puts "Results: #{results.inspect}"
end

# ========= Traceroute ============ TODO:
#
#require 'isolation_module'
#require '../spooftr_config.rb'
#
#controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
#registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)
#
#vps = controller.hosts.clone
#
#if !vps.empty?
#    curr_vp = vps[rand(vps.size)]
#    
#    results = registrar.traceroute(curr_vp, (ARGV.empty?) ? ["74.125.224.48", "128.208.4.244"] : ARGV, true) 
#
#    $stderr.puts "Results: #{results.inspect}"
#end
#
# ======== Spoofed Ping =======
#

#require 'isolation_module'
#require '../spooftr_config.rb'
#
#controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
#registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)
#
#vps = controller.hosts.clone
#
#i = 0
#
#if !vps.empty?
#    curr_vp = (ARGV.empty?) ? vps[i] : ARGV.shift
#    targets = (ARGV.empty?) ? ["128.208.3.88"] : ARGV
#    puts "curr_vp: #{curr_vp}"
#    vps.delete(curr_vp)
#
#    receive_results = registrar.receive_spoofed_pings(curr_vp, targets, vps, true)
#
#    puts "receive_results (target2receiver2succesfulsenders)"
#    puts receive_results.inspect
#    send_results = registrar.send_spoofed_pings(curr_vp, targets, vps, true)
#    puts "send_results (target2receiver2succesfulsenders)"
#    puts send_results.inspect
#end
#
#=   ======== Spoofed Traceroute =======
#$: << "../"
#
#require 'drb'
#require 'isolation_module'
#require 'failure_analyzer'
#require 'failure_dispatcher'
#
#uri = ARGV.shift
#
#controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
#registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)
#
#dispatcher = FailureDispatcher.new
#
#i = 0
#
#vps = controller.hosts.clone.delete_if { |h| h =~ /bgpmux/i }
#
#if !vps.empty?
#    i = (i + 1) % vps.size
#
#    curr_vp = (ARGV.empty?) ? vps[i] : ARGV.shift
#    targets = (ARGV.empty?) ? ["128.208.3.88"] : [ARGV.shift]
#    puts "curr_vp: #{curr_vp}"
#    vps.delete(curr_vp)
#
#    vps = (ARGV.empty?) ? vps : ARGV
#    
#    dst2ttlrtrs= registrar.batch_spoofed_traceroute({[curr_vp, targets.first] => vps})
#    puts dst2ttlrtrs
#end
#
# ====== Spoofed Revtr ========
#
#$: << File.expand_path("../")
#
#require 'isolation_module'
#require 'outage_correlation'
#require 'failure_analyzer'
#require 'outage'
#require 'suspect_set_processors'
#require 'db_interface'
#require 'isolation_utilities'
#Thread.abort_on_exception = true
#
#require 'failure_dispatcher'
#
##controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
##registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)
#
#uri = ARGV.shift
#uri ||= FailureIsolation::ControllerUri
#
#dispatcher = FailureDispatcher.new()
#hosts = DRb::DRbObject.new_with_uri(uri).hosts.sort_by { rand }.clone.find_all { |h| h.include? "bgpmux" } - ["prin.bgpmux"]
#
#src = hosts.first
#
#if !src.nil?
#    results = dispatcher.issue_revtr(src, "74.125.224.48")
#
#    $stderr.puts "Results: #{results.inspect}"
#end
