#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << "./"

# Main isolation process. Allocates several objects: 
#    - Failure Monitor (pulls ping logs, identifies partial outages)
#    - Failure Dispatcher (handed outages, issues isolation measurements, and
#    sends emails)
#    - Failure Analyzer (the "brains" of the business. Given isolation
#    measurements, runs isolation / other algorithms)
#
# Defines a global try/catch block to catch any exceptions and email them off.

# Ensure only one isolation processes at a time
require 'file_lock'
Lock::acquire_lock("isolation_lock.txt")

# TODO: These dependancies should be moved into the individual classes
# that need them

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

# TODO: move me into FailureIsolationConsts
$node_to_remove = "/homes/network/revtr/spoofed_traceroute/data/sig_usr2_node_to_remove.txt"
# Fail the main thread if any of the subthreads barf
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
       # Special treatment of USR1 signal: dynamically reload modules (for
       # development purposes)
       # TODO: when you reload modules, it looks like the old failure_monitor thread is
       # still running! it looks like threads are not garbage collected even if
       # there is not longer a reference to them
       logger.puts "reloading modules.."
       load 'auxiliary_modules.rb'

       # Reallocate all of the objects
       # TODO: put me into a helper method?
       logger = LoggerLog.new('/homes/network/revtr/revtr_logs/isolation_logs/isolation.log')
       logger.level = Logger::INFO
       db = DatabaseInterface.new(logger)
       dispatcher = FailureDispatcher.new(db, logger)
       monitor = FailureMonitor.new(dispatcher, db, logger) 
       monitor.start_pull_cycle((ARGV.empty?) ? FailureIsolation::DefaultPeriodSeconds : ARGV.shift.to_i)
   end

   Signal.trap("USR2") do
      # Special treatment of USR2 signal: remove a node from the
      # FailureMonitor's metadata
      node = IO.read($node_to_remove)
      if !node.nil?
         node.chomp!
         monitor.remove_node(node)
      end
   end

   # Loop infinitely
   monitor.start_pull_cycle((ARGV.empty?) ? FailureIsolation::DefaultPeriodSeconds : ARGV.shift.to_i)
rescue Exception => e
   # Catch all exceptions thrown at lower levels and send out an email with a
   # stacktrace
   Emailer.isolation_exception("#{e} \n#{e.backtrace.join("<br />")}").deliver
   $stderr.puts " Fatal error: #{e} \n#{e.backtrace.join("\n")}"
   monitor.persist_state unless monitor.nil?
   throw e
end
