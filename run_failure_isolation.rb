#!/homes/network/revtr/ruby/bin/ruby

require 'file_lock'
Lock::acquire_lock("isolation_lock.txt")

# TODO: ugggggly. These should be partitioned into the inidividual classes,
# but I don't have time to deal with it...
require 'isolation_module'
require 'drb'
require 'drb/acl'
require 'net/http'
require 'mail'
require 'yaml'
require 'time'
require 'fileutils'
require 'thread'
require 'reverse_traceroute_cache'
require 'ip_info'
require 'mkdot'
require 'hops'
require 'db_interface'
require 'revtr_cache_interface'
require 'failure_analyzer'
require 'failure_dispatcher'
require 'failure_monitor'

# XXX Don't hardcode!!!
$pptasks = "~ethan/scripts/pptasks"
$default_period_seconds = 360
$node_to_remove = "/homes/network/revtr/spoofed_traceroute/data/sig_usr2_node_to_remove.txt"
Thread.abort_on_exception = true

begin
   dispatcher = FailureDispatcher.new
   monitor = FailureMonitor.new(dispatcher)

   Signal.trap("TERM") { monitor.persist_state; exit }
   Signal.trap("KILL") { monitor.persist_state; exit }

   Signal.trap("USR1") do 
       $LOG.puts "reloading modules.."
       load 'ip_info.rb'
       load 'mkdot.rb'
       load 'hops.rb'
       load 'db_interface.rb'
       load 'revtr_cache_interface.rb'
       load 'failure_analyzer.rb'
       load 'failure_dispatcher.rb'
       load 'failure_monitor.rb'

       monitor = FailureMonitor.new(dispatcher)
       dispatcher = FailureDispatcher.new
       monitor.start_pull_cycle((ARGV.empty?) ? $default_period_seconds : ARGV.shift.to_i)
   end

   Signal.trap("USR2") do
      monitor.remove_node(IO.read($node_to_remove).chomp)
   end

    monitor.start_pull_cycle((ARGV.empty?) ? $default_period_seconds : ARGV.shift.to_i)
rescue Exception => e
   Emailer.deliver_isolation_exception("#{e} \n#{e.backtrace.join("<br />")}") 
   monitor.persist_state
   throw e
end
