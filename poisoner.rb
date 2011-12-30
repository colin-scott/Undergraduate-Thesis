
$: << "./"

# In charge of initiating BGP Poisonings and logging poisoning results

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
require 'isolation_mail'
require 'outage'
require 'utilities'
require 'direction'

# In charge of initiating BGP Poisonings and logging poisoning results
class Poisoner
    def initialize(failure_analyzer=FailureAnalyzer.new,db=DatabaseInterface.new, ip_info=IpInfo.new, logger=LoggerLog.new($stderr))
        @failure_analyzer = failure_analyzer
        @db = db 
        @ip_info = ip_info
        @logger = logger

        # TODO: threshold for outage duration! Don't want to poison outages
        # that will likely resolve themselves before poisoning is effective.
        # TODO: what about border routers? Which AS to poison?
    end

    # Check whether the merged_outage is worth poisoning. If so, poison!
    # "worth" is defined by:
    #   - source is a BGP Mux node
    #   - outage is reverse or bidirectional
    #   - outage passed filters
    def check_poisonability(merged_outage)
        # Direction is either FORWARD or BOTH
        src2direction2outage2failures = Hash.new { |h,k| h[k] = Hash.new { |h1,k1| h1[k1] = Hash.new { |h2,k2| h2[k2] = [] } } }

        merged_outage.each do |o|
            next unless FailureIsolation::PoisonerNames.include? o.src
            next unless o.passed_filters

            if o.direction == Direction.REVERSE
                # only base results on the old isolation algorithm!
                # TODO: at least until Arvind and I work out the correlation one
                
                if !o.suspected_failures[Direction.REVERSE].nil? and !o.suspected_failures[Direction.REVERSE].empty?
                    # POISON!!!!!!!!
                    src2direction2outage2failures[o.src][Direction.REVERSE][o] += o.suspected_failures[Direction.REVERSE]
                end
            elsif o.direction == Direction.BOTH and !o.suspected_failures[Direction.FORWARD].nil? and !o.suspected_failures[Direction.FORWARD].empty?
                # Note that in the old isolation algorithm suspects for bidirectional failures 
                # are computed from forward traceroutes
                # POISON!!!!!!!! 
                src2direction2outage2failures[o.src][Direction.BOTH][o] += o.suspected_failures[Direction.FORWARD]
            end
        end

        return if src2direction2outage2failures.empty?

        poison(src2direction2outage2failures, merged_outage)
    end

    # Choose the ASN to poison from the chosen outage, and execute a poisoning
    #
    # pre: all outages in src2direction2outage2failures are ready to be
    # poisoned (not just random)
    def poison(src2direction2outage2failures, merged_outage)
        if src2direction2outage2failures.empty?
            raise AssertionError.new("src2direction2outage2failures should not be empty!") 
        end

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
                execute_poison(src, asn_to_poison, outage)
            elsif direction2outage2failures.include? Direction.BOTH and !direction2outage2failures[Direction.BOTH].empty? 
                outage2failures = direction2outage2failures[Direction.BOTH]

                asn_to_poison, outage = asns_to_poison(outage2failures)

                if asn_to_poison.nil?
                    @logger.warn "asn_to_poison nil, both: #{direction2outage2failures[Direction.BOTH]}"
                    next
                end

                execute_poison(src, asn_to_poison, outage)
            else
                raise AssertionError.new("poison() should not see forward outages!")
            end
        end
        
        log_outages(src2direction2outage2failures)
    end

    # helper method. Given a merged_outage, return:
    #  [ the ASN to poison, the outage within the merged outage that was chosen]
    def asns_to_poison(outage2failures)
        outage2asns = outage2failures.map_values { |failures| failures.map  { |hop| hop.is_a?(String) ? @ip_info.getASN(hop) : hop.asn } }
        asns_to_poison = outage2asns.value_set.delete(nil).to_a

        asn_to_poison = asns_to_poison.mode

        outage = outage2asns.find { |k,v| v.include? asn_to_poison }[0]

        [asn_to_poison, outage]
    end

    # Log the results of the poisoning
    #
    # TODO: this is broken!
    def log_outages(src2direction2outage2failures)
        if src2direction2outage2failures.empty?
            raise AssertionError.new("src2direction2outage2failures should not be empty!") 
        end

        # <start time> <last modified time> <src> <dst> <direction> <suspected failures...>
        previous_outages = []
        begin
            previous_outages = YAML.load_file(FailureIsolation::CurrentMuxOutagesPath)
        rescue
            @logger.warn "failed to load yaml file #{$!}"
        end

        previous_outages = [] unless previous_outages
        
        current_time = Time.new

        src2direction2outage2failures.each do |src, direction2outage2failures|
            direction2outage2failures.each do |direction, outage2failures|
                outage2failures.each do |outage, failures|
                    # see if there was already an entry with the same
                    #   -  source, destination, and direction
                    already_there = previous_outages.find do |time_src_dst_dir_failures| 
                        time, prev_src, prev_dst, prev_direction, *prev_failures = time_src_dst_dir_failures
                        # the source, dstin
                        (prev_src == src && prev_dst == dst && prev_direction == prev_direction)
                    end

                    if already_there
                        already_there[1] = current_time  
                    else
                        formatted_failures = failures.map { |h| "#{h.ip} #{h.asn}" }
                        previous_outages << [current_time, current_time, src, outage.dst, outage.direction, formatted_failures].flatten
                    end
                end
            end
        end

        File.open(FailureIsolation::CurrentMuxOutagesPath, "w") { |f| YAML.dump(previous_outages, f) }
    end

    # ssh to riot and execute the poisoning
    def execute_poison(src, asn, outage)
        @logger.debug "Attempting to send poison notification email #{src} #{asn}"
        Emailer.poison_notification(outage).deliver

        # log event. On riot, I think
        # TODO: refactor this to be more easily testable (easier to mock out)
        system %{ssh cs@riot.cs.washington.edu "/home/cs/poisoning/execute_poison.rb #{src} #{asn}"} 
    end
end
