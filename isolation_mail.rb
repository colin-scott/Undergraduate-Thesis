#!/homes/network/revtr/ruby-upgrade/bin/ruby

$: << "./"

# ActionMailer module for sending various emails to the failures@ mailing list. 
# Copied directly from the reverse traceroute system (originally written by
# Ashoat)
#
# TODO: not sure why format() isn't being called automatically...

require 'rubygems'
require 'action_mailer'
require 'isolation_utilities.rb'

#ActionMailer::Base.delivery_method = :sendmail
# Sendmail isn't working with jruby, so we use smtp on our own
# uwfailures@gmail.com account
ActionMailer::Base.delivery_method = :smtp
ActionMailer::Base.smtp_settings = {
  :address              => "smtp.gmail.com",
  :port                 => 587,
  :domain               => 'yorker.cs.washington.edu',
  :user_name            => 'uwfailures',
  :password             => 'orcisten666',
  :authentication       => 'plain',
  :enable_starttls_auto => true  }

ActionMailer::Base.perform_deliveries = true
ActionMailer::Base.raise_delivery_errors = true
ActionMailer::Base.prepend_view_path("~revtr/spoofed_traceroute/reverse_traceroute/templates")
ActionMailer::Base.append_view_path("~revtr/spoofed_traceroute/reverse_traceroute/templates/emailer")

class Emailer < ActionMailer::Base
    @@logger = LoggerLog.new($stderr)

    def self.set_logger(logger)
        @@logger = logger
    end

    def test_email(email)
        mail(:subject => "Ashoat is testing!", 
             :from => "revtr@cs.washington.edu",
             :to => email)  do |format|
            format.html { render "test_email.text.html.erb" } 
        end
    end
    def successful_revtr(email, source, destination, traceroute)
        @source = source
        @destination = destination
        @traceroute = traceroute

        mail(:subject => "Reverse traceroute from #{destination} back to #{source}",
             :from => "revtr@cs.washington.edu",
             :to => email,
             :bcc => "revtr@cs.washington.edu")  do |format|
            format.html { render "succesful_revtr.text.html.erb" } 
        end
    end
    def timeout_error(email)
        mail(:subject => "[revtr error] Execution of measurement exceeded timeout",
             :from => "revtr@cs.washington.edu",
             :to => email,
             :bcc => "revtr@cs.washington.edu")  do |format|
            format.html { render "timeout_error.text.html.erb" } 
        end
    end
    def timeout_to_us(emails)
        @emails = emails

        mail(:subject => "[revtr error] Execution of measurement exceeded timeout",
             :from => "revtr@cs.washington.edu",
             :to => "revtr@cs.washington.edu") do |format|
            format.html { render "timeout_to_us.text.html.erb" } 
        end
    end
    def error(email)
        mail(:subject => "[revtr error] Error occurred!",
             :from => "revtr@cs.washington.edu",
             :to => email,
             :bcc => "revtr@cs.washington.edu") do |format|
            format.html { render "error.text.html.erb" } 
        end
    end
    def critical_error(script, error, backtrace, emails)
        @script = script
        @err = error
        @bt = backtrace
        @emails = emails

        mail(:subject => "[revtr error] CRITICAL ERROR OCCURRED!",
             :from => "revtr@cs.washington.edu",
             :to => "revtr@cs.washington.edu") do |format|
            format.html { render "critical_error.text.html.erb" } 
        end
    end
    def tr_parse_fail(source, destination, error, tr, log_id, email)
        @error = error
        @tr = tr
        @log_id = log_id
        @email = email

        mail(:subject => "Could not parse given traceroute from #{destination} back to #{source}",
             :from => "revtr@cs.washington.edu",
             :to => "revtr@cs.washington.edu") do |format|
            format.html { render "tr_parse_fail.text.html.erb" } 
        end
    end
    def tr_parse_success(source, destination, tr, revtr, parsed, log_id, email)
        @tr = tr
        @parsed = parsed
        @revtr = revtr
        @log_id = log_id
        @email = email

        mail(:subject => "Traceroute comparison results from #{destination} back to #{source}",
             :from => "revtr@cs.washington.edu",
             :to => "revtr@cs.washington.edu") do |format|
            format.html { render "tr_parse_success.text.html.erb" } 
        end
    end
    def tr_fail(email, source, destination)
        @source = source
        @dest = destination

        mail(:subject => "Reverse traceroute from #{destination} back to #{source}",
             :from => "revtr@cs.washington.edu",
             :to => email,
             :bcc => "revtr@cs.washington.edu") do |format|
            format.html { render "tr_fail.text.html.erb" } 
        end
    end
    def revtr_fail(email, source, destination)
        @source = source
        @dest = destination

        mail(:subject => "Reverse traceroute from #{destination} back to #{source}",
             :from => "revtr@cs.washington.edu",
             :to => email,
             :bcc => "revtr@cs.washington.edu") do |format|
            format.html { render "revtr_fail.text.html.erb" } 
        end
    end
    def blocked(email, source, destination)
        @dest = destination

        mail(:subject => "Reverse traceroute from #{destination} back to #{source}",
             :from => "revtr@cs.washington.edu",
             :to => email,
             :bcc => "revtr@cs.washington.edu") do |format|
            format.html { render "blocked.text.html.erb" } 
        end
    end
    def check_up_vps_issue(vps, issue)
        @vps = vps.join("<br />")
        @issue = issue

        mail(:subject => "VPs having trouble with #{issue}",
             :from => "revtr@cs.washington.edu",
             :to => "revtr@cs.washington.edu") do |format|
            format.html { render "check_up_vps_issue.text.html.erb" } 
        end
    end
    def isolation_results(merged_outage, recipient="failures@cs.washington.edu",
                          subject="Isolation: #{merged_outage.direction}; #{merged_outage.datasets.join ' '};" + 
                                   "sources: #{merged_outage.sources.join ' '}")
        @@logger.info { "Attempted to send isolation_results email" }

        @merged_outage = merged_outage

        mail(:subject => subject,
             :from => "uwfailures@gmail.com",
             :to => recipient) do |format|
            format.html { render "isolation_results.text.html.erb" } 
        end
    end
    # TODO: make a isolation_warning() message which indicates that the system
    # hasn't crashed, but we still want to be emailed about something
    def isolation_exception(exception, recipient="failures@cs.washington.edu")
        @@logger.info { "Attempted to send isolation_exception email #{exception}" }

        @exception = exception

        mail(:subject => "Isolation Module Exception",
             :from => "uwfailures@gmail.com",
             :to => recipient) do |format|
            format.html { render "isolation_exception.text.html.erb" } 
        end
    end
    def faulty_node_report(outdated_nodes, problems_at_the_source, not_sshable, not_controllable, failed_measurements,
                          bad_srcs, possibly_bad_srcs)
        @@logger.info { "Attempted to send faulty_node_report email" }

        @outdated_nodes = outdated_nodes
        @problems_at_the_source = problems_at_the_source
        @not_sshable = not_sshable
        @not_controllable = not_controllable
        @failed_measurements = failed_measurements
        @bad_srcs = bad_srcs
        @possibly_bad_srcs = possibly_bad_srcs

        mail(:subject => "faulty monitoring node report",
             :from => "uwfailures@gmail.com",
             :to => "failures@cs.washington.edu") do |format|
            format.html { render "faulty_node_report.text.html.erb" } 
        end
    end
    def isolation_status(dataset2unresponsive_targets, possibly_bad_targets, bad_hops, possibly_bad_hops)
        @@logger.info { "Attempted to send faulty_node_report email" }

        @dataset2unresponsive_targets = dataset2unresponsive_targets 
        @possibly_bad_targets = possibly_bad_targets
        @bad_hops = bad_hops
        @possibly_bad_hops = possibly_bad_hops

        mail(:subject => "Isolation target status",
             :from => "uwfailures@gmail.com",
             :to => "failures@cs.washington.edu") do |format|
            format.html { render "isolation_status.text.html.erb" } 
        end
    end
    def poison_notification(outage, recipient="failures@cs.washington.edu")
        @@logger.info { "Attempted to send poison_notification email" }

        @outage = outage
        
        mail(:subject => "Poison Opportunity!",
             :from => "uwfailures@gmail.com",
             :to => recipient) do |format|
            format.html { render "poison_notification.text.html.erb" } 
        end
    end
end

def email_and_die
    error = ($!.class.to_s == $!.message) ? $!.class.to_s : $!.class.to_s + ": " + $!.message;
    bt = $@.join("\n")
    $stderr.puts error
    $stderr.puts bt
    emails = "Luckily, the critical error didn't affect any users."
    if ($requests.is_a?(Array) && $requests.length > 0) then emails = "The following requests (by log ID) were affected: " + $requests.collect { |req| req.log.id.to_s + " (" + req.email + ")" }.join(", ") end
    Emailer.critical_error($0, error, bt, emails)
end

if __FILE__ == $0
    input_file = "#{FailureIsolation::MergedIsolationResults}/1_1_20120119220643.bin"
    merged_outage = Marshal.load(File.open(input_file.chomp))
    mail = Emailer.isolation_results(merged_outage, "ikneaddough@gmail.com")
    #mail = Emailer.isolation_exception("hi!", "ikneaddough@gmail.com")
    puts mail
    mail.deliver!
end
