#!/usr/bin/ruby

$: << "./"

# In charge of initiating BGP Poisonings and logging poisoning results

require 'failure_isolation_consts'
require 'drb'
require 'drb/acl'
require 'thread'
require 'ip_info'
require 'db_interface'
require 'yaml'
require 'net/http'
require 'hops'
require 'mkdot'
require 'reverse_traceroute_cache'
require 'timeout'
require 'failure_analyzer'
require 'isolation_mail'
require 'direction'
require 'outage'
require 'isolation_utilities.rb'
require 'direction'
require 'forwardable'
require 'pstore'
require 'java'
require 'thread'

Thread.abort_on_exception = true

class Timer

    def initialize(logger)
        @logger = logger
        @offset2callback = {}
        @mutex = Mutex.new
        @default_sleep_period = 10
         
        Thread.new do
            # would be simpler to just spin, but oh well...
            while true
                before_sleep = Time.now
                period = calculate_sleep_period
                sleep period if period > 0
                after_sleep = Time.now
                @offset2callback = update_times(after_sleep.to_i - before_sleep.to_i)
            end
        end
    end

    def update_times(seconds_passed)
        new_offset2callback = {}

        @mutex.synchronize do
            @offset2callback.each do |seconds, callback|
                new_seconds = seconds - seconds_passed
                if new_seconds <= 0
                    callback.call 
                else
                    new_offset2callback[new_seconds] = callback
                end
            end
        end

        new_offset2callback 
    end

    def calculate_sleep_period()
        sleep_period = @default_sleep_period
        @mutex.synchronize do
            sleep_period = @offset2callback.keys.min if @offset2callback.length>0
        end
        sleep_period
    end
    
    def add_callback(seconds_later, &block)
        @mutex.synchronize do
            @offset2callback[seconds_later] = block
            # simpler to just let the loop to its thing rather than updating
            # now
        end
    end
end

LogEntry = Struct.new(:start_time, :last_updated, :end_time, :src, :dst, :direction, :failures)

class PoisonLog
   # Write-through database, y'all.
   # TODO: use a real database
    
   extend Forwardable
   def_delegators :@previous_outages,:&,:*,:+,:-,:<=>,:[],:[],:[]=,:abbrev,:assoc,:at,:clear,:collect,
       :collect!,:compact,:compact!,:concat,:delete,:delete_at,:delete_if,:each,:each_index,
       :empty?,:fetch,:fill,:first,:flatten,:flatten!,:hash,:include?,:index,:indexes,:indices,
       :initialize_copy,:insert,:join,:last,:length,:map,:map!,:nitems,:pack,:pop,:push,:rassoc,
       :reject,:reject!,:replace,:reverse,:reverse!,:reverse_each,:rindex,:select,:shift,:size,
       :slice,:slice!,:sort,:sort!,:to_a,:to_ary,:transpose,:uniq,:uniq!,:unshift,:values_at,:zip,
       :|,:all?,:any?,:collect,:detect,:each_cons,:each_slice,:each_with_index,:entries,:enum_cons,
       :enum_slice,:enum_with_index,:find_all,:grep,:include?,:inject,:map,:max,:member?,:min,
       :partition,:reject,:select,:sort,:sort_by,:to_a,:to_set

    def initialize(logger)
        @logger = logger
        @previous_outages = reload
        @entry_queue = {}
        if @previous_outages.empty?
            @current_id = 0
        else
            @current_id = @previous_outages.keys.sort[-1] + 1
        end
    end

    def reload()
        @logger.debug { "Reloading poison log #{FailureIsolation::PoisonLogPath}" }
        # <id> <start time> <last modified time> <src> <dst> <direction> <suspected failures...>
        
        # id -> entry
        previous_outages = {}
        begin
            @store = PStore.new(FailureIsolation::PoisonLogPath, true)
            @store.transaction(true) do
                @store.roots.each do |key|
                   previous_outages[key] = @store[key]
                end
            end
        rescue java.lang.OutOfMemoryError => e
            raise "OOM here! #{e.backtrace.inspect}"
        rescue Exception
            @logger.warn { "failed to load yaml file #{$!}" }
        end

        previous_outages = {} unless previous_outages
        previous_outages
    end

    def <<(entry)
        @current_id += 1
        @entry_queue[@current_id] = entry
    end

    # Return nil if no entry existed
    #
    # If multiple entries match, return the most recent one
    def find_previous_entry(src, dst, direction)
        # see if there was already an entry with the same
        #   -  source, destination, and direction
        already_there = @previous_outages.values.reverse.find do |log_entry|
            log_entry.src == src && log_entry.dst == dst && log_entry.direction == direction
        end
    end

    def commit()
      @store.transaction do
        # We assign a unique id for each of today's filter stat objects
        # For now, we use t+src+dst
        @entry_queue.each do |id, entry|
            @store[id] = entry
        end
      end

      @previous_outages.merge!(@entry_queue)
      @entry_queue = {}
    end
end

# In charge of initiating BGP Poisonings and logging poisoning results
class Poisoner
    attr_accessor :poison_log

    def initialize(failure_analyzer=FailureAnalyzer.new,db=DatabaseInterface.new, ip_info=IpInfo.new, logger=LoggerLog.new($stderr), unpoison_timeout_seconds=6*60*60)
        @failure_analyzer = failure_analyzer
        @db = db 
        @ip_info = ip_info
        @logger = logger
        @poison_log = PoisonLog.new(logger)
        @timer_loop = Timer.new(logger)
        @unpoison_timeout_seconds = unpoison_timeout_seconds

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
            raise "src2direction2outage2failures should not be empty!"
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
                    @logger.warn { "asn_to_poison nil, reverse: #{direction2outage2failures[Direction.REVERSE]}" }
                    next
                end
                execute_poison(src, asn_to_poison, outage)
            elsif direction2outage2failures.include? Direction.BOTH and !direction2outage2failures[Direction.BOTH].empty? 
                outage2failures = direction2outage2failures[Direction.BOTH]

                asn_to_poison, outage = asns_to_poison(outage2failures)

                if asn_to_poison.nil?
                    @logger.warn { "asn_to_poison nil, both: #{direction2outage2failures[Direction.BOTH]}" }
                    next
                end

                execute_poison(src, asn_to_poison, outage)
            else
                raise "poison() should not see forward outages!"
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
            raise "src2direction2outage2failures should not be empty!"
        end

        current_time = Time.new

        src2direction2outage2failures.each do |src, direction2outage2failures|
            direction2outage2failures.each do |direction, outage2failures|
                outage2failures.each do |outage, failures|
                    already_there = @poison_log.find_previous_entry(src, outage.dst, outage.direction)

                    if already_there
                        already_there.last_updated = current_time  
                    else
                        formatted_failures = failures.map { |h| "#{h.ip} #{h.asn}" }
                        @poison_log << LogEntry.new(current_time, current_time, nil, src, outage.dst, outage.direction, formatted_failures)
                    end
                end
            end
        end

        @poison_log.commit
    end

    def already_poisoning?(src)
        `#{FailureIsolation::CurrentPoisoningsPath}`.include? src
    end

    # ssh to riot and execute the poisoning
    def execute_poison(src, asn, outage)
        if already_poisoning? src
            @logger.warn { "#{src} is already poisoning... ignoring poison opportunity" }
            return 
        end

        @logger.debug { "before poison" }
        # Y U THRASH?
        Emailer.isolation_warning("Poisoning #{src} #{asn}").deliver

        @logger.debug { "about to poison" }
        # (logs event on riot)
        system "#{FailureIsolation::ExecutePoisonPath} #{src} #{asn}"

        @logger.debug { "about to add timer" }
        @timer_loop.add_callback(@unpoison_timeout_seconds) do
            @logger.debug { "executing timer callback" }
            system "#{FailureIsolation::UnpoisonPath} #{src}" 
            t = Time.new
            @poison_log.find_previous_entry(src, outage.dst, outage.direction).end_time = t
            @poison_log.commit
        end
    end
end

if __FILE__ == $0
    current_time = Time.new
    src = "1.2.3.4"
    dst = "4.5.5.6"
    direction = Direction.REVERSE
    formatted_failures = []

    puts "I live in a giant coconut"

    #LogEntry.new(current_time, current_time, nil, src, dst, direction, formatted_failures)
    #p = PoisonLog.new(LoggerLog.new($stderr))
    #puts p.find_previous_entry(src, dst, direction)

    p = Poisoner.new(FailureAnalyzer.new,DatabaseInterface.new,IpInfo.new,LoggerLog.new($stderr),1)
    outage1 = Marshal.load(IO.read("tests/fixtures/mlab1.ath01.measurement-lab.org_193.138.215.1_20110921081833.bin"))

    #require 'rubygems'
    #require 'ruby-debug'
    #debugger
    p.execute_poison("FOOBAR", 12345, outage1)
    sleep
end

