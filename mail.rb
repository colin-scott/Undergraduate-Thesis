#!/homes/network/revtr/ruby-upgrade/bin/ruby

# AcionMailer module for sending various emails to the failures@ mailing list. 
# Copied directly from the reverse traceroute system (originally written by
# Ashoat)

require_relative 'failure_isolation_consts'
require_relative 'utilities'
require 'action_mailer'

ActionMailer::Base.delivery_method = :sendmail
#ActionMailer::Base.template_root = "#{$REV_TR_TOOL_DIR}/templates"
ActionMailer::Base.prepend_view_path("#{$REV_TR_TOOL_DIR}/templates")
#$TEMPLATE_PATH = "#{$REV_TR_TOOL_DIR}/templates"
ActionMailer::Base.raise_delivery_errors = true

class Emailer < ActionMailer::Base
    LOGGER = LoggerLog.new($stderr)

    def test_email(email)
        mail :subject => "Ashoat is testing!", 
             :from => "revtr@cs.washington.edu",
             :recipients => email
    end
    def successful_revtr(email, source, destination, traceroute)
        @source = source
        @destination = destination
        @traceroute = traceroute

        mail :subject => "Reverse traceroute from #{destination} back to #{source}",
             :from => "revtr@cs.washington.edu",
             :recipients => email,
             :bcc => "revtr@cs.washington.edu"
    end
    def timeout_error(email)
        mail :subject => "[revtr error] Execution of measurement exceeded timeout",
             :from => "revtr@cs.washington.edu",
             :recipients => email,
             :bcc => "revtr@cs.washington.edu"
    end
    def timeout_to_us(emails)
        @emails = emails

        mail :subject => "[revtr error] Execution of measurement exceeded timeout",
             :from => "revtr@cs.washington.edu",
             :recipients => "revtr@cs.washington.edu"
    end
    def error(email)
        mail :subject => "[revtr error] Error occurred!",
             :from => "revtr@cs.washington.edu",
             :recipients => email,
             :bcc => "revtr@cs.washington.edu"
    end
    def critical_error(script, error, backtrace, emails)
        @script = script
        @err = error
        @bt = backtrace
        @emails = emails

        mail :subject => "[revtr error] CRITICAL ERROR OCCURRED!",
             :from => "revtr@cs.washington.edu",
             :recipients => "revtr@cs.washington.edu"
    end
    def tr_parse_fail(source, destination, error, tr, log_id, email)
        @error = error
        @tr = tr
        @log_id = log_id
        @email = email

        mail :subject => "Could not parse given traceroute from #{destination} back to #{source}",
             :from => "revtr@cs.washington.edu",
             :recipients => "revtr@cs.washington.edu"
    end
    def tr_parse_success(source, destination, tr, revtr, parsed, log_id, email)
        @tr = tr
        @parsed = parsed
        @revtr = revtr
        @log_id = log_id
        @email = email

        mail :subject => "Traceroute comparison results from #{destination} back to #{source}",
             :from => "revtr@cs.washington.edu",
             :recipients => "revtr@cs.washington.edu"
    end
    def tr_fail(email, source, destination)
        @source = source
        @dest = destination

        mail :subject => "Reverse traceroute from #{destination} back to #{source}",
             :from => "revtr@cs.washington.edu",
             :recipients => email,
             :bcc => "revtr@cs.washington.edu"
    end
    def revtr_fail(email, source, destination)
        @source = source
        @dest = destination

        mail :subject => "Reverse traceroute from #{destination} back to #{source}",
             :from => "revtr@cs.washington.edu",
             :recipients => email,
             :bcc => "revtr@cs.washington.edu"
    end
    def blocked(email, source, destination)
        @dest = destination

        mail :subject => "Reverse traceroute from #{destination} back to #{source}",
             :from => "revtr@cs.washington.edu",
             :recipients => email,
             :bcc => "revtr@cs.washington.edu"
    end
    def check_up_vps_issue(vps, issue)
        @vps = vps.join("<br />")
        @issue = issue

        mail :subject => "VPs having trouble with #{issue}",
             :from => "revtr@cs.washington.edu",
             :recipients => "revtr@cs.washington.edu"
    end
    def isolation_results(merged_outage)
        LOGGER.info "Attempted to send isolation_results email"

        @merged_outage = merged_outage

        mail :subject => "Isolation: #{merged_outage.direction}; #{merged_outage.datasets.join ' '}; sources: #{merged_outage.sources.join ' '}",
             :from => "failures@cs.washington.edu",
             :recipients => "failures@cs.washington.edu"
    end
    def isolation_exception(exception, recipient="failures@cs.washington.edu")
        LOGGER.info "Attempted to send isolation_exception email"

        @exception = exception

        mail :subject => "Isolation Module Exception",
             :from => "failures@cs.washington.edu",
             :recipients => recipient
    end
    def faulty_node_report(outdated_nodes, problems_at_the_source, not_sshable, not_controllable, failed_measurements,
                          bad_srcs, possibly_bad_srcs)
        LOGGER.info "Attempted to send faulty_node_report email"

        @outdated_nodes = outdated_node
        @problems_at_the_source = problems_at_the_source
        @not_sshable = not_sshable
        @not_controllable = not_controllable
        @failed_measurements = failed_measurements
        @bad_srcs = bad_srcs
        @possibly_bad_srcs = possibly_bad_src

        mail :subject => "faulty monitoring node report",
             :from => "failures@cs.washington.edu",
             :recipients => "failures@cs.washington.edu"
    end
    def isolation_status(dataset2unresponsive_targets, possibly_bad_targets, bad_hops, possibly_bad_hops)
        LOGGER.info "Attempted to send faulty_node_report email"

        @dataset2unresponsive_targets = dataset2unresponsive_targets 
        @possibly_bad_targets = possibly_bad_targets
        @bad_hops = bad_hops
        @possibly_bad_hops = possibly_bad_hops

        mail :subject => "Isolation target status",
             :from => "failures@cs.washington.edu",
             :recipients => "failures@cs.washington.edu"
    end
    def poison_notification(outage)
        LOGGER.info "Attempted to send poison_notification email"

        @outage = outage
        
        mail :subject => "Poison Opportunity Detected!",
             :from => "failures@cs.washington.edu",
             :recipients => "failures@cs.washington.edu"
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
    puts Emailer.isolation_exception("how did you get here").class
    puts Emailer.isolation_status({},[],[],[])
end
