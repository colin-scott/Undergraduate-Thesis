$: << "../"

require 'failure_isolation_consts'
require 'action_mailer'
require 'drb'
require 'fileutils'
require 'ip_info'

module TestVars
    IsolationResults = "/tmp/isolation_results"
    MergedIsolationResults = "/tmp/merged_isolation_results"
    FilterStatsPath = "/tmp/filter_stats"
    DotFiles = "/tmp/dots"
    CurrentMuxOutagesPath = "/tmp/mock_mux_log.yml"

    # TODO: have the system grab fake ping monitor state? That would be a great
    # end-to-end test. Would need to mock out measurements.

    CONTROLLER = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
    REGISTRAR = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)
    VPS = CONTROLLER.hosts.clone.delete_if { |h| h =~ /bgpmux/i }
    IP_INFO = IpInfo.new

    # Returns [src, [reciever_1, receiver_2, ...,receiver_n-1]]
    def self.get_n_registered_vps(n=5)
        VPS.shuffle!
        src = VPS.first
        receivers = VPS[1..n]
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
    FileUtils.rm_rf CurrentMuxOutagesPath
end

# Monkey Wrench email methods to go only to Colin
#  TODO: possibly don't send the email at all -- rather, set a boolean flag
#  "finished" to enable asserts
class Emailer < ActionMailer::Base
    def isolation_results(merged_outage)
        LOGGER.debug "Attempted to send isolation_results email"

        @merged_outage = merged_outage

        mail :subject => "Isolation: #{merged_outage.direction}; #{merged_outage.datasets.join ' '}; sources: #{merged_outage.sources.join ' '}",
             :from => "failures@cs.washington.edu",
             :recipients => "ikneaddough@gmail.com"
    end
    def isolation_exception(exception, recipient="ikneaddough@gmail.com")
        LOGGER.debug "Attempted to send isolation_exception email"

        @exception = exception

        mail :subject => "Isolation Module Exception",
             :from => "failures@cs.washington.edu",
             :recipients => recipient
    end
    def faulty_node_report(outdated_nodes, problems_at_the_source, not_sshable, not_controllable, failed_measurements,
                          bad_srcs, possibly_bad_srcs)
        LOGGER.debug "Attempted to send faulty_node_report email"

        @outdated_nodes = outdated_node
        @problems_at_the_source = problems_at_the_source
        @not_sshable = not_sshable
        @not_controllable = not_controllable
        @failed_measurements = failed_measurements
        @bad_srcs = bad_srcs
        @possibly_bad_srcs = possibly_bad_src

        mail :subject => "faulty monitoring node report",
             :from => "failures@cs.washington.edu",
             :recipients => "ikneaddough@gmail.com"
    end
    def isolation_status(dataset2unresponsive_targets, possibly_bad_targets, bad_hops, possibly_bad_hops)
        LOGGER.debug "Attempted to send faulty_node_report email"

        @dataset2unresponsive_targets = dataset2unresponsive_targets 
        @possibly_bad_targets = possibly_bad_targets
        @bad_hops = bad_hops
        @possibly_bad_hops = possibly_bad_hops

        mail :subject => "Isolation target status",
             :from => "failures@cs.washington.edu",
             :recipients => "ikneaddough@gmail.com"
    end
    def poison_notification(outage)
        LOGGER.debug "Attempted to send poison_notification email"

        @outage = outage
        
        mail :subject => "Poison Opportunity Detected!",
             :from => "failures@cs.washington.edu",
             :recipients => "ikneaddough@gmail.com"
    end
end
