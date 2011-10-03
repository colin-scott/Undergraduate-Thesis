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
        
        # TODO: what about a border router?
    end

    def check_poisonability(merged_outage, testing=false)
        src2direction2outage2failures = Hash.new { |h,k| h[k] = Hash.new { |h1,k1| h1[k1] = Hash.new { |h2,k2| h2[k2] = [] } } }

        merged_outage.each do |o|
            next unless FailureIsolation::PoisonerNames.include? o.src
            next unless o.passed_filters

            if o.direction == Direction.REVERSE
                # only base results on the old isolation algorithm!
                #   at least until Arvind and I work out the correlation one
                
                if !o.suspected_failures[Direction.REVERSE].nil? and !o.suspected_failures[Direction.REVERSE].empty?
                    # POISON!!!!!!!!
                    src2direction2outage2failures[o.src][Direction.REVERSE][o] += o.suspected_failures[Direction.REVERSE]
                end
            elsif o.direction == Direction.BOTH and !o.suspected_failures[Direction.FORWARD].nil? and !o.suspected_failures[Direction.FORWARD].empty?
                # POISON!!!!!!!! 
                src2direction2outage2failures[o.src][Direction.FORWARD][o] += o.suspected_failures[Direction.FORWARD]
            end
        end

        poison(src2direction2outage2failures, merged_outage, testing)
    end

    # pre: !suspected_failures.empty?
    def poison(src2direction2outage2failures, outage, testing)
        # for now, we only poison a single ASN at a time
        # find the set of all sources
        # then prioritize:
        #    reverse path first
        #    then, which bidirectional outage had the majority of suspected
        #    failures in same AS

        src2direction2outage2failures.each do |src, direction2outage2failures|
            if direction2outage2failures.include? Direction.REVERSE and !direction2outage2failures[Direction.REVERSE].empty?
                outage2failures = direction2outage2failures[Direction.REVERSE]

                asn_to_poison, outage = asns_to_poison(outage2failures)

                if asn_to_poison.nil?
                    @logger.warn "asn_to_poison nil, reverse: #{direction2outage2failures[Direction.REVERSE]}"
                    next
                end
                execute_poison(src, asn_to_poison, outage, testing)
            elsif !direction2outage2failures[Direction.FORWARD].empty? # Direction.FORWARD
                outage2failures = direction2outage2failures[Direction.FORWARD]

                asn_to_poison, outage = asns_to_poison(outage2failures)

                if asn_to_poison.nil?
                    @logger.warn "asn_to_poison nil, both: #{direction2outage2failures[Direction.FORWARD]}"
                    next
                end

                execute_poison(src, asn_to_poison, outage, testing)
            end
        end
    end

    def asns_to_poison(outage2failures)
        outage2asns = outage2failures.map_values { |failures| failures.map  { |hop| hop.is_a?(String) ? @ip_info.getASN(hop) : hop.asn } }
        asns_to_poison = outage2asns.value_set.delete(nil).to_a

        asn_to_poison = asns_to_poison.mode

        outage = outage2asns.find { |k,v| v.include? asn_to_poison }[0]

        [asn_to_poison, outage]
    end

    def execute_poison(src, asn, outage, testing)
        @logger.debug "Attempting to send poison notification email #{src} #{asn}"
        Emailer.deliver_poison_notification(outage, testing)

        # log event. On riot, I think
        # poison
        system %{ssh cs@riot.cs.washington.edu "/home/cs/poisoning/execute_poison.rb #{src} #{asn}"} if !testing
    end
end
