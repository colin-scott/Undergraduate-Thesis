require 'failure_isolation_consts'
require 'drb'
require 'drb/acl'
require 'thread'
require 'ip_info'
require 'db_interface'
require 'yaml'
require 'revtr_cache_interface'
require 'net/http'
require 'hops'
require 'mkdot'
require 'reverse_traceroute_cache'
require 'timeout'
require 'failure_analyzer'
require 'mail'
require 'outage'
require 'utilities'
require 'direction'

class Poisoner
    def initialize(failure_analyzer=FailureAnalyzer.new,db=DatabaseInterface.new, ip_info=IpInfo.new, logger=LoggerLog.new($stderr))
        @failure_analyzer = failure_analyzer
        @db = db 
        @ip_info = ip_info
        @logger = logger

        # TODO: threshold for outage duration!
        #
        # TODO: what about a border router?
    end

    def check_poisonability(merged_outage, testing=false)
        src2direction2failures = Hash.new { |h,k| h[k] = Hash.new { |h1,k1| h1[k1] = [] } }

        merged_outage.each do |o|
            next unless FailureIsolation::PoisonerNames.include? o.src
            next unless o.passed_filters

            if o.direction == Direction.REVERSE
                # only base results on the old isolation algorithm!
                #   at least until Arvind and I work out the correlation one
                
                if !o.suspected_failures[Direction.REVERSE].nil? and !o.suspected_failures[Direction.REVERSE].empty?
                    # POISON!!!!!!!!
                    Emailer.deliver_poison_notification(o, testing)
                    src2direction2failures[o.src][o.direction] += o.suspected_failures[Direction.REVERSE]
                end
            elsif o.direction == Direction.BOTH and !o.suspected_failures[Direction.FORWARD].nil? and !o.suspected_failures[Direction.FORWARD].empty?
                # POISON!!!!!!!!
                Emailer.deliver_poison_notification(o, testing)
                src2direction2failures[o.src][o.direction] += o.suspected_failures[Direction.FORWARD]
            end
        end

        poison(src2direction2failures) unless src2direction2failures.empty?
    end

    # pre: !suspected_failures.empty?
    def poison(src2direction2failures)
        # for now, we only poison a single ASN at a time
        # find the set of all sources
        # then prioritize:
        #    reverse path first
        #    then, which bidirectional outage had the majority of suspected
        #    failures in same AS

        src2direction2failures.each do |src, direction2failures|
            if direction2failures.include? Direction.REVERSE
                asns_to_poison = direction2failures[Direction.REVERSE].map { |h| h.is_a?(String) ? @ip_info.getASN(h) : h.asn }\
                                                                      .delete(nil)

                asn_to_poison = asns_to_poison.delete(nil).mode
                next if asn_to_poison.nil?
                execute_poison(src, asn_to_poison)
            else # Direction.BOTH
                # redundant, but I don't cayur
                asns_to_poison = direction2failures[Direction.FORWARD].map { |h| h.is_a?(String) ? @ip_info.getASN(h) : h.asn }\
                                                                      .delete(nil)

                asn_to_poison = asns_to_poison.delete(nil).mode
                next if asn_to_poison.nil?
                execute_poison(src, asn_to_poison)
            end
        end
    end

    def execute_poison(src, asn)
        # log event. On riot, I think
        # poison
        system %{ssh cs@riot.cs.washington.edu "/home/cs/poisoning/execute_poison.rb #{src} #{asn}"}
    end
end
