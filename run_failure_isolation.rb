#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << "./"

if RUBY_PLATFORM == "java"
    require 'rubygems'
end

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
require 'db_interface'
require 'pstore'
require 'failure_monitor'
require 'isolation_utilities.rb'
require 'isolation_mail'
require 'active_record'
require 'fileutils'
require 'drb'
require 'drb/acl'
require 'net/http'
require 'yaml'
require 'time'
require 'thread'
require 'reverse_traceroute_cache'
require 'ip_info'
require 'mkdot'
require 'hops'
require 'failure_analyzer'
require 'failure_dispatcher'
require 'java'

# TODO: move me into FailureIsolationConsts
$node_to_remove = "/homes/network/revtr/spoofed_traceroute/data/sig_usr2_node_to_remove.txt"
# Fail the main thread if any of the subthreads barf
Thread.abort_on_exception = true

# starting DRb server so we can use @controller.issue_command_on_hosts
# added by cunha so we can get tcpdump on VPs
DRb.start_service

def allocate_modules(logger)
   ip_info = IpInfo.new
   db = DatabaseInterface.new(logger, ip_info)
   house_cleaner = HouseCleaner.new(logger, db)
   dispatcher = FailureDispatcher.new(db, logger, house_cleaner, ip_info)
   monitor = FailureMonitor.new(dispatcher, db, logger, house_cleaner)
   monitor
end

begin
   logger = LoggerLog.new('/homes/network/revtr/revtr_logs/isolation_logs/isolation.log')
   logger.level = Logger::DEBUG
   Emailer.set_logger(logger)
   monitor = allocate_modules(logger)

   Signal.trap("TERM") { monitor.persist_state; exit }
   Signal.trap("KILL") { monitor.persist_state; exit }

   Signal.trap("ALRM") do 
       # NOTE: I would like to use USR1, but that's taken by the JVM
       # Special treatment of USR1 signal: dynamically reload modules (for
       # development purposes)
       # TODO: when you reload modules, it looks like the old failure_monitor thread is
       # still running! it looks like threads are not garbage collected even if
       # there is not longer a reference to them
       logger.puts "reloading modules.."
       load 'auxiliary_modules.rb'

       # Reallocate all of the objects
       monitor = allocate_modules(logger)
       monitor.start_pull_cycle()
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

   Signal.trap("WINCH") do
       # NOTE: I would like to use some other signal, but they're taken by the JVM
       # SIGWINCH means new historical traces are ready to be loaded
       FailureIsolation.grab_historical_traces          
    end

   # Loop infinitely
   monitor.start_pull_cycle()
rescue java.lang.OutOfMemoryError => e
   # Catch all exceptions thrown at lower levels and send out an email with a
   # stacktrace
   stacktraces = []
   Thread.list.each do |t|
       begin
           t.raise(Exception.new("trying to get backtrace"))
       rescue Exception => r
           stacktrace = "Thread #{t} "
           stacktrace << "backtrace: #{r.backtrace.join("\n")}" unless r.backtrace.nil?
           logger.warn { stacktrace }
       end
   end
   Emailer.isolation_exception("Thrashing: \n#{stacktraces.join "\n"}")
   # fail fast!
   throw e unless e.nil?
rescue Exception => e
   # TODO: if e has a cause, print it (until there are no more causes). 
   Emailer.isolation_exception("#{e} \n#{e.backtrace.join("<br />")}").deliver
   # fail fast!
   throw e unless e.nil?
ensure
   # Send to log in case email doesn't go through
   monitor.persist_state unless monitor.nil?
   logger.close unless logger.nil?
end
