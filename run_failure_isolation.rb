#!/homes/network/revtr/ruby/bin/ruby

# Main isolation process. Allocates several objects: 
#    - Failure Monitor (pulls ping logs, identifies partial outages)
#    - Failure Dispatcher (handed outages, issues isolation measurements, and
#    sends emails)
#    - Failure Analyzer (the "brains" of the business. Given isolation
#    measurements, runs isolation / other algorithms)

require 'file_lock'
Lock::acquire_lock("isolation_lock.txt")

# TODO: These dependancies  should be partitioned into the inidividual classes,
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

$node_to_remove = "/homes/network/revtr/spoofed_traceroute/data/sig_usr2_node_to_remove.txt"
Thread.abort_on_exception = true

begin
   logger = LoggerLog.new('/homes/network/revtr/revtr_logs/isolation_logs/isolation.log')
   logger.level = Logger::INFO
   db = DatabaseInterface.new(logger)
   dispatcher = FailureDispatcher.new(db, logger)
   monitor = FailureMonitor.new(dispatcher, db, logger) 

   Signal.trap("TERM") { monitor.persist_state; exit }
   Signal.trap("KILL") { monitor.persist_state; exit }

   Signal.trap("USR1") do 
       logger.puts "reloading modules.."
       load 'auxiliary_modules.rb'

       # killall threads
       # 
       # will threads be garbage collected if objects are garbage collected?  
       dispatcher = FailureDispatcher.new(db, logger)
       monitor = FailureMonitor.new(dispatcher, db, logger)
       monitor.start_pull_cycle((ARGV.empty?) ? FailureIsolation::DefaultPeriodSeconds : ARGV.shift.to_i)
   end

   Signal.trap("USR2") do
      node = IO.read($node_to_remove)
      if !node.nil?
         node.chomp!
         monitor.remove_node(node)
      end
   end

   Signal.trap("ALRM") do
     #fork do
     #  ObjectSpace.each_object(Thread) do |th|
     #    th.raise Exception, "Stack Dump" unless Thread.current == th
     #  end
     #  raise Exception, "Stack Dump"
     #end
   end

   monitor.start_pull_cycle((ARGV.empty?) ? FailureIsolation::DefaultPeriodSeconds : ARGV.shift.to_i)
rescue Exception => e
   Emailer.deliver_isolation_exception("#{e} \n#{e.backtrace.join("<br />")}") 
   monitor.persist_state unless monitor.nil?
   throw e
end
