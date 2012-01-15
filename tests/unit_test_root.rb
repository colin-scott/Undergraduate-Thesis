
$: << "../"

require 'failure_isolation_consts'
require 'action_mailer'
require 'drb'
require 'fileutils'
require 'ip_info'
require 'isolation_utilities'
require 'rspec'
require 'set'
require 'db_interface'
require 'failure_monitor'
require 'failure_dispatcher'
require 'house_cleaner'

Thread.abort_on_exception = true

module TestVars
    IsolationResults = "/tmp/isolation_results"
    MergedIsolationResults = "/tmp/merged_isolation_results"
    FilterStatsPath = "/tmp/filter_stats"
    DotFiles = "/tmp/dots"
    PoisonLogPath = "/tmp/mock_mux_log.yml"
    NonReachableTargetPath = "/tmp/targets_never_seen.yml"
    LastObservedOutagePath = "/tmp/last_outages.yml"

    FailureIsolation.module_eval("remove_const :PingStatePath")
    FailureIsolation::PingStatePath = "/homes/network/revtr/spoofed_traceroute/reverse_traceroute/tests/ping_monitoring_state/"

    # To make unit tests run faster, assume that targets haven't changed since
    # last bootup
    FailureIsolation.module_eval(%{@TargetSet = Set.new(IO.read(TargetSetPath).split("\n"))})

    Controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
    Registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)
    VPs = Controller.hosts.clone.delete_if { |h| h =~ /bgpmux/i }
    @IpInfo = nil
    def self.IpInfo()
       @IpInfo ||= IpInfo.new 
    end

    Logger = LoggerLog.new($stderr)
    DB = DatabaseInterface.new(Logger)
    HouseCleaner = HouseCleaner.new(Logger, DB)
    @dispatcher = nil
    def self.Dispatcher
        @dispatcher ||= FailureDispatcher.new(DB, Logger, HouseCleaner, self.IpInfo)
    end
    @monitor = nil
    def self.Monitor
        @monitor ||= FailureMonitor.new(self.Dispatcher, DB, Logger, HouseCleaner)
    end

    # Returns [src, [reciever_1, receiver_2, ...,receiver_n-1]]
    def self.get_n_registered_VPs(n=5)
        VPs.shuffle!
        src = VPs.first
        receivers = VPs[1..n]
        [src, receivers]
    end

    def self.make_fake_log_dir(path)
        FileUtils.rm_rf path
        FileUtils.mkdir_p path
    end

    # private:

    # Re-write constants in FailureIsolation
    ["IsolationResults", "MergedIsolationResults", "FilterStatsPath", "DotFiles"].each do |var|
       # Get the values (too lazy to type out a hash)
       val = TestVars.module_eval(var)
       # Re-write FailureIsolation's constant
       FailureIsolation.module_eval("remove_const :#{var}")
       FailureIsolation.module_eval("#{var} = '#{val}'")
       # Make the path
       self.make_fake_log_dir(val)
    end

    # Clear previous test case data
    FileUtils.rm_rf PoisonLogPath

    # Add fake data to node2targetneverseen.yml
    targets_never_seen = {
      "pl1.rcc.uottawa.ca" => [],
      "planetlab2.tamu.edu" => [],
      "planetlab-1.sjtu.edu.cn" => [],
      "planetlab3-dsl.cs.cornell.edu" => [],
      "plgmu5.ite.gmu.edu" => [],
      "plnode-04.gpolab.bbn.com" => [],
      "dschinni.planetlab.extranet.uni-passau.de" => [],
      "pli1-pa-4.hpl.hp.com" => [],
      "planet-lab1.itba.edu.ar" => [],
      "planetlab1.csuohio.edu" => [],
      "planetlab2.poly.edu" => [],
      "planetlab-01.ece.uprm.edu" => [],
      "planetlab-1.calpoly-netlab.net" => [],
      "prin.bgpmux" => []
    }
    
    File.open(FailureIsolation::NonReachableTargetPath, "w") { |f| YAML.dump(targets_never_seen, f) }
end

# Monkey Wrench email methods to go only to Colin
#  TODO: possibly don't send the email at all -- rather, set a boolean flag
#  "finished" to enable asserts
class Emailer < ActionMailer::Base
    def isolation_results(merged_outage)
        Logger.debug "Attempted to send isolation_results email"

        @merged_outage = merged_outage

        mail :subject => "Isolation: #{merged_outage.direction}; #{merged_outage.datasets.join ' '}; sources: #{merged_outage.sources.join ' '}",
             :from => "failures@cs.washington.edu",
             :to => "ikneaddough@gmail.com"
    end
    def isolation_exception(exception, recipient="ikneaddough@gmail.com")
        Logger.debug "Attempted to send isolation_exception email"

        @exception = exception

        mail :subject => "Isolation Module Exception",
             :from => "failures@cs.washington.edu",
             :to => recipient
    end
    def faulty_node_report(outdated_nodes, problems_at_the_source, not_sshable, not_controllable, failed_measurements,
                          bad_srcs, possibly_bad_srcs)
        Logger.debug "Attempted to send faulty_node_report email"

        @outdated_nodes = outdated_node
        @problems_at_the_source = problems_at_the_source
        @not_sshable = not_sshable
        @not_controllable = not_controllable
        @failed_measurements = failed_measurements
        @bad_srcs = bad_srcs
        @possibly_bad_srcs = possibly_bad_src

        mail :subject => "faulty monitoring node report",
             :from => "failures@cs.washington.edu",
             :to => "ikneaddough@gmail.com"
    end
    def isolation_status(dataset2unresponsive_targets, possibly_bad_targets, bad_hops, possibly_bad_hops)
        Logger.debug "Attempted to send faulty_node_report email"

        @dataset2unresponsive_targets = dataset2unresponsive_targets 
        @possibly_bad_targets = possibly_bad_targets
        @bad_hops = bad_hops
        @possibly_bad_hops = possibly_bad_hops

        mail :subject => "Isolation target status",
             :from => "failures@cs.washington.edu",
             :to => "ikneaddough@gmail.com"
    end
    def poison_notification(outage)
        Logger.debug "Attempted to send poison_notification email"

        @outage = outage
        
        mail :subject => "Poison Opportunity Detected!",
             :from => "failures@cs.washington.edu",
             :to => "ikneaddough@gmail.com"
    end
end

