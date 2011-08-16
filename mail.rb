#!/homes/network/revtr/ruby/bin/ruby

require 'isolation_module'
require 'action_mailer'

ActionMailer::Base.delivery_method = :sendmail
ActionMailer::Base.template_root = "#{$REV_TR_TOOL_DIR}/templates"
ActionMailer::Base.raise_delivery_errors = true

class Emailer < ActionMailer::Base
    def test_email(email)
        subject     "Ashoat is testing!"
        from        "revtr@cs.washington.edu"
        recipients  email
    end
    def successful_revtr(email, source, destination, traceroute)
        subject     "Reverse traceroute from #{destination} back to #{source}"
        from        "revtr@cs.washington.edu"
        recipients  email
        bcc         "revtr@cs.washington.edu"
        body        :traceroute => traceroute
    end
    def timeout_error(email)
        subject     "[revtr error] Execution of measurement exceeded timeout"
        from        "revtr@cs.washington.edu"
        recipients  email
        bcc         "revtr@cs.washington.edu"
    end
    def timeout_to_us(emails)
        subject     "[revtr error] Execution of measurement exceeded timeout"
        from        "revtr@cs.washington.edu"
        recipients  "revtr@cs.washington.edu"
        body        :emails => emails
    end
    def error(email)
        subject     "[revtr error] Error occurred!"
        from        "revtr@cs.washington.edu"
        recipients  email
        bcc         "revtr@cs.washington.edu"
    end
    def critical_error(script, error, backtrace, emails)
        subject     "[revtr error] CRITICAL ERROR OCCURRED!"
        from        "revtr@cs.washington.edu"
        recipients  "revtr@cs.washington.edu"
        body        :script => script, :err => error, :bt => backtrace, :emails => emails
    end
    def tr_parse_fail(source, destination, error, tr, log_id, email)
        subject     "Could not parse given traceroute from #{destination} back to #{source}"
        from        "revtr@cs.washington.edu"
        recipients  "revtr@cs.washington.edu"
        body        :error => error, :tr => tr, :log_id => log_id, :email => email
    end
    def tr_parse_success(source, destination, tr, revtr, parsed, log_id, email)
        subject     "Traceroute comparison results from #{destination} back to #{source}"
        from        "revtr@cs.washington.edu"
        recipients  "revtr@cs.washington.edu"
        body        :tr => tr, :parsed => parsed, :revtr => revtr, :log_id => log_id, :email => email
    end
    def tr_fail(email, source, destination)
        subject     "Reverse traceroute from #{destination} back to #{source}"
        from        "revtr@cs.washington.edu"
        recipients  email
        bcc         "revtr@cs.washington.edu"
        body        :source => source, :dest => destination
    end
    def revtr_fail(email, source, destination)
        subject     "Reverse traceroute from #{destination} back to #{source}"
        from        "revtr@cs.washington.edu"
        recipients  email
        bcc         "revtr@cs.washington.edu"
        body        :source => source, :dest => destination
    end

    def blocked(email, source, destination)
        subject     "Reverse traceroute from #{destination} back to #{source}"
        from        "revtr@cs.washington.edu"
        recipients  email
        bcc         "revtr@cs.washington.edu"
        body        :dest => destination
    end
    
    def check_up_vps_issue(vps, issue)
        subject     "VPs having trouble with #{issue}"
        from        "revtr@cs.washington.edu"
        recipients  "revtr@cs.washington.edu"
        body        :vps => vps.join("<br />"), :issue => issue
    end

    def outage_detected(target, dataset, disconnected, connected, never_seen,
                        problems_at_the_source, outdated_nodes,
                        not_sshable, testing=false)
        subject     "Outage detected: #{target}"
        from        "failures@cs.washington.edu"
        recipients  (testing) ? "cs@cs.washington.edu" : "failures@cs.washington.edu"
        body        :target => target, :dataset => dataset, :disconnected => disconnected,
                    :connected => connected, :never_seen => never_seen,
                    :problems_at_the_source => problems_at_the_source,
                    :outdated_nodes => outdated_nodes, :not_sshable => not_sshable
    end

    def isolation_results(outage, testing=false)
        subject     (outage.symmetric) ? "Ground Truth Isolation Results #{src} #{dst}" \
                                       : "Isolation Results #{src} #{dst}"
        
        from        "failures@cs.washington.edu"
        recipients  (testing) ? "cs@cs.washington.edu" : "failures@cs.washington.edu"

        body        :outage => outage
    end
    def isolation_exception(exception, recipient="failures@cs.washington.edu")
        subject     "Isolation Module Exception"
        from        "failures@cs.washington.edu"
        recipients  recipient
        body        :exception => exception
    end
    def faulty_node_report(outdated_nodes, problems_at_the_source, not_sshable, failed_measurements,
                          bad_srcs, possibly_bad_srcs)
        subject     "faulty monitoring node report"
        from        "failures@cs.washington.edu"
        recipients  "failures@cs.washington.edu"
        body         :outdated_nodes => outdated_nodes,
                     :problems_at_the_source => problems_at_the_source,
                     :not_sshable => not_sshable,
                     :failed_measurements => failed_measurements,
                     :bad_srcs => bad_srcs,
                     :possibly_bad_srcs => possibly_bad_srcs
    end
    def dot_graph(jpg_path)
        name = File.basename(jpg_path)
        subject     "Failure Isolation Graph Results #{name}"
        from        "failures@cs.washington.edu"
        recipients  "failures@cs.washington.edu"
        attachment  :filename => name, :content_type => "image/jpeg", :body => File.read(jpg_path) 
    end
end

def email_and_die
    error = ($!.class.to_s == $!.message) ? $!.class.to_s : $!.class.to_s + ": " + $!.message;
    bt = $@.join("\n")
    $stderr.puts error
    $stderr.puts bt
    emails = "Luckily, the critical error didn't affect any users."
    if ($requests.is_a?(Array) && $requests.length > 0) then emails = "The following requests (by log ID) were affected: " + $requests.collect { |req| req.log.id.to_s + " (" + req.email + ")" }.join(", ") end
    Emailer.deliver_critical_error($0, error, bt, emails)
end
