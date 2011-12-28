$: << "../"

require 'failure_isolation_consts'
require 'action_mailer'
require 'fileutils'

def make_fake_log_dir(path)
    FileUtils.rm_rf path
    FileUtils.mkdir_p path
end

isolation_results = "/tmp/isolation_results"
make_fake_log_dir(isolation_results)
FailureIsolation::IsolationResults = isolation_results

merged_isolation_results = "/tmp/merged_isolation_results"
make_fake_log_dir(merged_isolation_results)
FailureIsolation::MergedIsolationResults = merged_isolation_results

filter_stats = "/tmp/filter_stats"
make_fake_log_dir(filter_stats)
FailureIsolation::FilterStatsPath = filter_stats

dot_files = "/tmp/dots"
make_fake_log_dir(dot_files)
FailureIsolation::DotFiles = dot_files

# TODO: have the system grab fake ping monitor state? That would be a great
# end-to-end test

# Monkey Wrench email methods to go only to Colin
#  TODO: possibly don't send the email at all -- rather, set a boolean flag
#  "finished" to enable asserts
class Emailer < ActionMailer::Base
  def outage_detected(target, dataset, disconnected, connected, never_seen,
                        problems_at_the_source, outdated_nodes,
                        not_sshable)
        subject     "Outage detected: #{target}"
        from        "failures@cs.washington.edu"
        recipients  "ikneaddough@gmail.com" 
        body        :target => target, :dataset => dataset, :disconnected => disconnected,
                    :connected => connected, :never_seen => never_seen,
                    :problems_at_the_source => problems_at_the_source,
                    :outdated_nodes => outdated_nodes, :not_sshable => not_sshable
  end

  def isolation_results(merged_outage)
        subject "Isolation: #{merged_outage.direction}; #{merged_outage.datasets.join ' '}; sources: #{merged_outage.sources.join ' '}"
        
        from        "failures@cs.washington.edu"
        recipients  "ikneaddough@gmail.com"

        body        :merged_outage => merged_outage
  end

  def poison_notification(outage)
        subject "Poison Opportunity Detected!"
        from "failures@cs.washington.edu"
        recipients "ikneaddough@gmail.com"
        body :outage => outage
  end
end

class UnitTest
    def initialize()
        @controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
        @registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)
        @vps = @controller.hosts.clone.delete_if { |h| h =~ /bgpmux/i }
    end

    # Returns [src, [reciever_1, receiver_2, ...,receiver_n-1]]
    def get_n_registered_vps(n=5)
        @vps.shuffle!
        src = @vps.first
        receivers = @vps[1..n]
        [src, receivers]
    end
end
