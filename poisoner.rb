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
    def intializer(failure_analyzer=FailureAnalyzer.new,db=DatabaseInterface.new, ip_info=IpInfo.new, logger=LoggerLog.new($stderr))
        @failure_analyzer = failure_analyzer
        @db = db 
        @ip_info = ip_info
        @logger = logger

        # TODO: threshold for outage duration!
        #
        # TODO: what about a border router?
    end

    def check_poisonability(merged_outage, testing=false)
        merged_outage.each do |o|
            next unless FailureIsolation::PoisonerNames.include? o.src
            next unless o.passed_filters

            if o.direction == Direction.REVERSE
                # only base results on the old isolation algorithm!
                #   at least until Arvind and I work out the correlation one
                
                if !o.suspected_failures[Direction.REVERSE].nil? and !o.suspected_failures[Direction.REVERSE].empty?
                    # POISON!!!!!!!!
                    Emailer.deliver_poison_notification(o, testing)
                    poison(o.src, o.suspected_failures[Direction.REVERSE])
                end
            elsif o.direction == Direction.BOTH and !o.suspected_failures[Direction.FORWARD].nil? and !o.suspected_failures[Direction.FORWARD].empty?
                # POISON!!!!!!!!
                Emailer.deliver_poison_notification(o, testing)
                poison(o.src, o.suspected_failures[Direction.FORWARD])
            end
        end
    end

    # pre: !suspected_failures.empty?
    def poison(src, suspected_failures)
        first_hop = suspected_failures.first

        if(first_hop.is_a?(String)
            suspected_asn = @ip_info.getASN(first_hop) 
        else
            suspected_asn = first_hop.asn
        end
        return if suspected_asn.nil?

        # log event
        
        # poison
    end
end
