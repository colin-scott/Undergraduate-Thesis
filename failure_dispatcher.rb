$: << "./"

# Coordinate measurements for detected measurements, and log/email results

require 'outage'
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
require 'isolation_utilities.rb'
#require 'poisoner'
require 'filters'
require 'pstore'
require 'timeout'
require 'house_cleaner'
require 'isolation_issuer'
require 'java'
require 'rubygems'
require 'rufus/tokyo'

$TEST_THREADS = false
if RUBY_PLATFORM == "java"
    require 'java'
    java_import java.util.concurrent.Executors
    # TODO: HACK. Make me a platform-independant class variable
    $executor = Executors.newFixedThreadPool(5)
    $executor.setMaximumPoolSize(5)
end

# This guy is just in charge of issuing measurements and logging/emailing results
#
# TODO: log additional traceroutes
# TODO: make use of logger levels so we don't have to comment out log
# statements
class FailureDispatcher
    # Keep track of how many time a node has returned empty measurement
    # results. (we assume that the size of this field is constant)
    attr_accessor :node_2_failed_measurements  

    def initialize(db=DatabaseInterface.new, logger=LoggerLog.new($stderr), house_cleaner=HouseCleaner.new, ip_info=IpInfo.new)
        @logger = logger
        @house_cleaner = house_cleaner

        # TODO: will this ACL work with the new ruby upgrade?
        acl=ACL.new(%w[deny all
					allow *.cs.washington.edu
					allow localhost
                    allow 128.208.2.*
					allow 127.0.0.1
					])

        # Only allow one thread at a time to access Dave's DRB server
        @drb_mutex = Mutex.new
        
        connect_to_drb() # sets @rtrSvc
        @have_retried_connection = false # so that multiple threads don't try to reconnect to DRb

        @ipInfo = ip_info
        @db = db
        @isolation_issuer = MeasurementRequestor.new(@logger, @ipInfo)
        @failure_analyzer = FailureAnalyzer.new(@ipInfo, @logger, @db)

        # track when nodes fail to return tr or ping results
        @node_2_failed_measurements = Hash.new(0)

        @dot_generator = DotGenerator.new(@logger, $ASN_TO_ISP_MAP, @ip_info)

        #@poisoner = Poisoner.new(@failure_analyzer, @db, @ipInfo, @logger)

	    @node2emptypings = Hash.new{ |h,k| h[k] = EmptyStats.new(100) }

        @max_thread_wait_time_minutes = 15 # number of minutes to wait for measurement threads to complete
         
        # See http://rufus.rubyforge.org/rufus-tokyo/ for information on Tokyo
        # Cabinet + the Rufus FFI
        @filter_store = Rufus::Tokyo::Table.new(FailureIsolation::FilterStatsPath,
                                                :lcnum => 1, :ncnum => 5)

        @outage_store = Rufus::Tokyo::Table.new(FailureIsolation::IsolationResults,
                                                :lcnum => 1, :ncnum => 5)

        @merged_outage_store = Rufus::Tokyo::Table.new(FailureIsolation::MergedIsolationResults,
                                                :lcnum => 1, :ncnum => 5)

    end

    # Connect to Dave's spoofed revtr DRB service
    def connect_to_drb()
        @drb_mutex.synchronize do
            if !@have_retried_connection
                begin
                    @have_retried_connection = true
                    uri_location = "http://revtr.cs.washington.edu/vps/failure_isolation/spoof_only_rtr_module.txt"
                    uri = Net::HTTP.get_response(URI.parse(uri_location)).body
                    @rtrSvc = DRbObject.new nil, uri
                    @rtrSvc.respond_to?(:anything?)
                rescue DRb::DRbConnError
                    # Email only gets sent to Dave for now
                    Emailer.isolation_warning("Revtr Service is down!", "choffnes@cs.washington.edu").deliver
                end 
            end
        end
    end

    # Return the currently registered VPs
    #
    # Send a warning email if no VPs are registered or all VPs are quarentined
    def sanity_check_registered_vps
        registered_vps = []
        under_quarantine = []
        ProbeController.issue_to_controller do |controller|
            registered_vps = controller.hosts.clone
            under_quarantine = controller.under_quarantine.clone
        end

        if registered_vps.empty?
            Emailer.isolation_warning("No VPs are registered with the controller!").deliver
        elsif Set.new(under_quarantine) == Set.new(registered_vps)
            Emailer.isolation_warning("All VPs are quarentined!").deliver
        end

        registered_vps
    end

    # Issue measurements, merge (src dst) outages, invoke isolation algorithm, and email results
    #
    # precondition: stillconnected are able to reach dst
    def isolate_outages(srcdst2outage, srcdst2filter_tracker)
        # Set this to false at the beginning of each round
        @have_retried_connection = false

        # Note that no Outage objects are allocated for filtered (src,dst) pairs 
        assert_no_outage_loss(srcdst2outage.size, srcdst2filter_tracker) { |srcdst2outage| srcdst2outage.size }

        # ================================================================================
        # Invoke registration filters                                                    #
        # ================================================================================
        srcdst2still_connected = srcdst2outage.map_values { |o| o.connected }
        @logger.info { "before filtering, srcdst: #{srcdst2still_connected.keys.inspect}" }

        registered_vps = sanity_check_registered_vps
        # Note: filter! removes srcdst2outages where the registration filters
        # did not pass
        RegistrationFilters.filter!(srcdst2outage, srcdst2filter_tracker, registered_vps, @house_cleaner)

        srcdst2still_connected = srcdst2outage.map_values { |o| o.connected }
        @logger.info { "after filtering, srcdst: #{srcdst2still_connected.keys.inspect}" }

        # Not that RegistrationFilters.filter! deletes filtered srcdst2outage entries
        assert_no_outage_loss(srcdst2outage.size, srcdst2filter_tracker)

        # ================================================================================
        # Issue Measurements                                                             #
        # ================================================================================
        now = Time.new
        srcdst2filter_tracker.each { |srcdst, filter_tracker| filter_tracker.measurement_start_time = now }
        measurement_times = []

        # NOTE: We issue spoofed pings/traces globally to avoid race conditions over spoofer   #
        #  ids
        # TODO: integrate Italo's icmpid fixes so that we don't have to issue
        # globally like this
        
        # quickly isolate the directions of the failures
        measurement_times << ["spoof_ping", Time.new]
        # mutates outage.pings_towards_srcs
        @isolation_issuer.issue_pings_towards_srcs!(srcdst2outage)
        @logger.debug { "pings towards source issued" }

        # if we control one of the targets, (later) send out spoofed traceroutes in
        # the opposite direction for ground truth information
        dstsrc2outage = check4targetswecontrol(srcdst2outage, registered_vps)
        @logger.debug { "dstsrc2outage: " + dstsrc2outage.inspect }

        # we check the forward direction by issuing spoofed traceroutes (which subsume spoofed pings)
        measurement_times << ["spoof_tr", Time.new]
        @isolation_issuer.issue_spoofed_traceroutes!(srcdst2outage, dstsrc2outage)
        @logger.debug { "spoofed traceroute issued" }

        # Now thread out on each src,dst pair, and issue the remaining
        # measurements in parallel
        Thread.new do
            measurement_start = Time.new
            outage_threads = []
            srcdst2outage.each do |srcdst, outage|
                block = lambda do
                    src,dst = srcdst
                    filter_tracker = srcdst2filter_tracker[srcdst]
                    outage.measurement_times += deep_copy(measurement_times)
                    process_srcdst_outage(outage, filter_tracker)
                end

                if $executor
                    outage_threads << $executor.submit(&block)
                else
                    outage_threads << Thread.new(&block)
                end
            end

            # TODO: Should I really be joining here if there are going to be
            # more measurements issued for MergedOutage? There currently
            # aren't more measurement issued for MergedOutages, but we might
            # have them in the future
            t = Time.new
            
            # join on threads
            grab_thread_results(outage_threads)
            
            t_prime = Time.new
            @logger.info { "Took #{t_prime - t} seconds to join on measurement threads" }
            # TODO: use a thread pool to keep # threads constant
            @logger.info { "Total threads in the system after join: #{Thread.list.size}" }

            srcdst2filter_tracker.each { |srcdst, filter_tracker| filter_tracker.end_time = t_prime } 

            # Note that outage.passed? is now initialized
            total_passed_outages = srcdst2outage.find_all { |srcdst,outage| outage.passed? }.size
            assert_no_outage_loss(total_passed_outages, srcdst2filter_tracker)

            # ================================================================================
            # Merge (src, dst) outages                                                       #
            # ================================================================================
            # DRC confirmed that this was not the source of the leak 
            merged_outages = merge_outages(srcdst2outage, srcdst2filter_tracker)
            merged_outage_threads = []

            merged_outages.each do |merged_outage|
                block = lambda { process_merged_outage(merged_outage) }
                if $executor
                    merged_outage_threads << $executor.submit(&block)
                else
                    merged_outage_threads << Thread.new(&block)
                end
            end

            # Don't want to block the rest of the system here..
            # But we still want to see exceptions if they happen
            Thread.new { grab_thread_results(merged_outage_threads) }

            measurement_end = Time.new
            @logger.info { "Measurments took #{measurement_end - measurement_start} seconds" }

            swap_out_faulty_nodes(srcdst2filter_tracker)
            log_filter_trackers(srcdst2filter_tracker)
        end
    end

    # java Executors hide stack traces... to help with debugging, uncover
    # the underlying stacktrace
    def grab_thread_results(threads)
      # TODO: this barrier might take arbitrarily long. Mostly needed
      # for merging pruposes, but we might consider instrumenting this
      # and doing something smarter if it's a bottleneck
      start_time = Time.now.to_i
      threads.each do |thread|
          remaining_time = (@max_thread_wait_time_minutes*60) - (Time.now.to_i-start_time)
          if remaining_time < 1 then remaining_time = 1 end
          @logger.debug{"Thread #{thread}: Remaining time: #{remaining_time}"}
          begin 
              # thread.get will throw an exception if the underlying thread
              # threw an exception during execution
              if $executor
                  java_import java.util.concurrent.TimeUnit
                  thread.get(remaining_time*1000, TimeUnit::MILLISECONDS) 
              else 
                  thread.join
              end
          rescue Exception => e
              if $executor
                  # Two levels of nesting to get at the real exception!
                  # jruby, sometimes you do weird things...
                  begin
                    e = e.cause if e.cause
                    e = e.cause if e.cause
                  rescue Exception # catch errors this generates...
                    # What errors is it generating??? That might be good to
                    # know ;-)
                  end
                  raise e
              else
                  raise e
              end
          end
          if $executor then thread.cancel(true) end # should do nothing if done, but needs to happen to free up threads otherwise
      end
    end

    # Invariant: there should always be a one-to-one mapping between trackers and outages
    def assert_no_outage_loss(num_passed_outages, srcdst2filter_tracker)
       num_passed_trackers = srcdst2filter_tracker.find_all { |srcdst, filter_tracker| filter_tracker.passed? }.size
       if num_passed_outages != num_passed_trackers
           @logger.warn { "# of passed outages (#{num_passed_outages}) != # of passed filters (#{num_passed_trackers}) #{caller[0..3]}" }
       end
    end

    # At the end of the measurement pipeline, swap out nodes with consistent
    # empty pings
    def swap_out_faulty_nodes(srcdst2filter_tracker)
        sources_to_swap = Set.new
        srcdst2filter_tracker.each do |srcdst, tracker|
            next if (SwapFilters::TRIGGERS & tracker.failure_reasons).empty?
            sources_to_swap.add srcdst[0]
        end

        @house_cleaner.swap_out_faulty_nodes(sources_to_swap.to_a) unless sources_to_swap.empty?
    end

    # Cluster together (src, dst) outages into MergedOutage objects. A single
    # (src, dst) outage may appear in multiple MergedOutage objects if it
    # satifisfies multiple clustering algorithms.
    # 
    # TODO: use smarter merging heuristics?
    def merge_outages(srcdst2outage, srcdst2filter_tracker)
       # TODO should freeze these objects
       outages = srcdst2outage.values
       # Assign unique ids to outages
       @outage_store.transaction do
           outages.each do |outage|
                outage.file = @outage_store.generate_unique_id
           end
       end

       # nested helper closure
       allocate_merged_outage = lambda do |outage_list, merging_method|
           id = nil
           merged_outage = nil
           # Generate a unique id
           @merged_outage_store.transaction do
               id = @merged_outage_store.generate_unique_id 
               merged_outage = MergedOutage.new(id, outage_list, merging_method)
           end
           outage_list.each do |outage|
                src = outage.src
                dst = outage.dst
                srcdst2filter_tracker[[src,dst]].merged_outage_ids << id
           end

           # last statement is the map value
           merged_outage
       end
       
       # Note: bidirectional will appear twice, in forward mergings and reverse
       # mergings
       only_forward = outages.find_all { |o| o.direction.is_forward? }
       dst2outages = only_forward.categorize_on_attr(:dst) 
       # Abuse of map... 
       forward_merged = dst2outages.values.map do |outage_list|
           allocate_merged_outage.call(outage_list, MergingMethod::FORWARD)
       end

       only_reverse = outages.find_all { |o| o.direction.is_reverse? }
       src2outages = only_reverse.categorize_on_attr(:src)
       # Abuse of map... 
       reverse_merged = src2outages.values.map do |outage_list|
           allocate_merged_outage.call(outage_list, MergingMethod::REVERSE)
       end

       # For debugging. TODO: put me into unit tests instead of here.
       forward_src_dsts = Set.new(forward_merged.map { |merged| merged.map { |o| {:src => o.src, :dst => o.dst}  } }.flatten)
       reverse_src_dsts = Set.new(reverse_merged.map { |merged| merged.map { |o| {:src => o.src, :dst => o.dst}  } }.flatten)
       all_outages = Set.new(outages.find_all { |o| o.direction.is_forward? or o.direction.is_reverse? }.map { |o| {:src => o.src, :dst => o.dst} })
       if (forward_src_dsts | reverse_src_dsts).size != all_outages.size
           # forward U reverse mergings should contain every (src, dst) pair
           # TODO: raise rather than log?
           @logger.warn { "Not merging properly! [#{forward_src_dsts.to_a.inspect} #{reverse_src_dsts.to_a.inspect} #{all_outages.to_a.inspect}]" }
       end
       
       return forward_merged + reverse_merged
    end

    # To gather ground truth data, check for cases where the destination is
    # under our control
    def check4targetswecontrol(srcdst2outage, registered_hosts)
       dstsrc2outage = {}

       srcdst2outage.each do |srcdst, outage|
            src, dst = srcdst
            if FailureIsolation.SpooferTargets.include? dst
                # Need to convert dst IP -> hostname, and source hostname -> IP
                dst_hostname = @db.ip2hostname[dst]
                @logger.info { "check4targetswecontrol: dst ip is: #{dst}, dst_hostname is: #{dst_hostname}. ip mismap?" } if dst_hostname.nil?

                if registered_hosts.include? dst_hostname
                    outage.symmetric = true
                    # TODO: Possible problem with ip2hostname mappings? This
                    # might be the cause of the missing ground truth data
                    outage.src_ip = @db.hostname2ip[src]
                    outage.dst_hostname = dst_hostname
                    dstsrc2outage[[outage.dst_hostname, outage.src_ip]] = outage
                end
            end
       end

       dstsrc2outage
    end

    # Gather measurements and generate DOT graphs for a single (src, dst) outage
    #
    # Return whether the outage passed second level filters
    def process_srcdst_outage(outage, filter_tracker)
        @logger.debug { "process_srcdst_outage: #{outage.src}, #{outage.dst}" }

        gather_measurements(outage, filter_tracker)

        # turn into a linked list ( I think? )
        @logger.debug { "process_srcdst_outage: building outage!: #{outage.src}, #{outage.dst}" }
        outage.build!

        if @failure_analyzer.passes_filtering_heuristics?(outage, filter_tracker)
            # Generate a DOT graph
            outage.jpg_output = generate_jpg(outage)

            outage.graph_url = generate_web_symlink(outage.jpg_output)
        else
            @logger.debug { "Heuristic failure! measurement times: #{outage.measurement_times.inspect}" }
        end

        log_srcdst_outage(outage)

        return outage.passed_filters
    end

    # Process a MergedOutage object. Analyze the measurements, log the
    # results, and send out an email if passed second level filters.
    def process_merged_outage(merged_outage)
        @logger.debug { "process_merged_outage: #{merged_outage.sources}, #{merged_outage.destinations}" }
        analyze_measurements(merged_outage)
    
        @logger.debug { "got_past_analyze: #{merged_outage.sources}, #{merged_outage.destinations}" }
        log_merged_outage(merged_outage)
        @logger.debug { "got_past_log: #{merged_outage.sources}, #{merged_outage.destinations}" }

        # If one of the riot VPs, attempt to trigger a BGP poison
        #@poisoner.check_poisonability(merged_outage)
        @logger.debug { "got_past_poisonability: #{merged_outage.sources}, #{merged_outage.destinations}" }

        if(merged_outage.is_interesting?)
            # at least one of the inside outages passed filters, so email
            Emailer.isolation_results(merged_outage).deliver
        end
    end

    # Run analaysis on the merged_outage object with FailureAnalyzer
    def analyze_measurements(merged_outage)
        #TODO: move all of these method sigatures to take a single outage
        @failure_analyzer.identify_faults(merged_outage)

        merged_outage.each do |outage|
            # This is happening redundantly for outages that appear in multiple merged
            # outages... oh well
            outage.alternate_paths = @failure_analyzer.find_alternate_paths(outage.src, outage.dst, outage.direction, outage.tr,
                                                        outage.spoofed_tr, outage.historical_tr, outage.spoofed_revtr, outage.historical_revtr)

            outage.measured_working_direction = @failure_analyzer.measured_working_direction?(outage.direction, outage.spoofed_revtr)

            outage.path_changed = @failure_analyzer.path_changed?(outage.historical_tr, outage.tr, outage.spoofed_tr, outage.direction)
        end
    end

    # Gather all necessary measurements for a single (src, dst) outage, and
    # set the appropriate fields in the outage object.
    #
    # TODO: I should figure out a better way to gather data, rather
    # than this longgg method
    def gather_measurements(outage, filter_tracker)
        reverse_problem = outage.pings_towards_src.empty?
        forward_problem = (outage.spoofed_tr.nil? || !outage.spoofed_tr.reached?(outage.dst))

        outage.direction = @failure_analyzer.infer_direction(reverse_problem, forward_problem)
        @logger.debug { "direction: #{outage.direction}" }

        # HistoricalForwardHop objects
        outage.historical_tr, outage.historical_trace_timestamp = retrieve_historical_tr(outage.src, outage.dst)

        @logger.debug { "Finding historical revtrs for #{outage.historical_tr.length} hops" }
        outage.historical_tr.each do |hop|
            # thread out on this to make it faster? Ask Dave for a faster
            # way?
            hop.reverse_path = fetch_historical_revtr(outage.src, hop.ip)
        end

        outage.historical_revtr = fetch_historical_revtr(outage.src, outage.dst)

        @logger.debug { "historical paths fetched" }

        # maybe not accurate given multiple threads, but fukit
        tr_time = Time.new
        outage.measurement_times << ["tr_time", tr_time]
        outage.tr = @isolation_issuer.issue_normal_traceroutes(outage.src, outage.dst)[outage.dst]

        @logger.debug { "traceroutes issued" }

        ## I see empty measurements from time to time, which shouldn't happen
        if outage.tr.empty?
            @logger.warn { "empty traceroute! #{outage.src} #{outage.dst}" }
            restart_atd(outage.src)
            sleep 10
            tr_time2 = Time.new
            outage.tr = @isolation_issuer.issue_normal_traceroutes(outage.src, outage.dst)[outage.dst]
            if outage.tr.empty?
                @logger.warn { "traceroute still empty! (#{outage.src}, #{outage.dst})" } 
                @node_2_failed_measurements[outage.src] += 1
            end
        end

        # Set to the # of times measurements were reissued. False of
        # measurements succeeded on the first attempt
        measurements_reissued = false

        if outage.paths_diverge?
            # path divergence!
            # reissue traceroute and spoofed traceroute until they don't
            # diverge
            measurements_reissued = 1

            3.times do 
                sleep 30
                outage.tr = @isolation_issuer.issue_normal_traceroutes(outage.src, outage.dst)[outage.dst]
                @isolation_issuer.issue_spoofed_traceroutes!({[outage.src,outage.dst] => outage})

                break if !outage.paths_diverge?
                measurements_reissued += 1
            end
        end

        # TODO: implement retries for symmetric traceroutes? (in an attempt to
        # fill in the gaps of the missing ground truth data)

        # We would like to know whether the hops on the historicalfoward/reverse/historicalreverse paths
        # are pingeable from the source.
        outage.measurement_times << ["non-revtr pings", Time.new]
        # Note that outage.ping_responsive() is computed on demand. The return
        # value here is only used to check if need to reissue pings
        responsive_hops, non_responsive_hops = @isolation_issuer.check_reachability!(outage)
        responsive_ips, non_responsive_ips = hops_to_uniq_ips(responsive_hops), hops_to_uniq_ips(non_responsive_hops)

        @logger.debug { "non-revtr pings issued" }

        ## Moar empty measurements!
        if responsive_ips.empty?
            @logger.warn { "empty pings! (#{outage.src}, #{outage.dst} #{responsive_ips.size + non_responsive_ips.size} ips: [#{non_responsive_ips.join(",")}])" }

            @node2emptypings[outage.src].push_empty
            restart_atd(outage.src)
            sleep 10
            responsive_hops, non_responsive_hops = @isolation_issuer.check_reachability!(outage)
            responsive_ips, non_responsive_ips = hops_to_uniq_ips(responsive_hops), hops_to_uniq_ips(non_responsive_hops)
            if responsive_ips.empty?
                @logger.warn { "pings still empty! (#{outage.src}, #{outage.dst} #{responsive_ips.size + non_responsive_ips.size} ips: [#{non_responsive_ips.join(",")}])" } 
                @node_2_failed_measurements[outage.src] += 1
                @node2emptypings[outage.src].push_empty
            else
                @node2emptypings[outage.src].push_nonempty
            end
        else
            @node2emptypings[outage.src].push_nonempty
        end

        outage.measurement_times << ["pings_to_nonresponsive_hops", Time.new]
        @isolation_issuer.check_pingability_from_other_vps!(outage.connected, non_responsive_hops)

        @logger.debug { "pings to non-responsive hops issued" }

        if outage.direction != Direction.REVERSE and outage.direction != Direction.BOTH
            # Only issue spoofed revtrs for forward outages (since spoofed
            # revtrs take a looooong time to measure)
            outage.measurement_times << ["revtr", Time.new]
            outage.spoofed_revtr = issue_revtr(outage.src, outage.dst, outage.historical_tr.map { |hop| hop.ip })
        else
            # Else, just set it to an empty path
            outage.spoofed_revtr = SpoofedReversePath.new(outage.src, outage.dst)
        end

        @logger.debug { "spoofed_revtr issued" }

        if outage.spoofed_revtr.valid?
            # Issue pings to all hops on the spoofed revtr
           outage.measurement_times << ["revtr pings", Time.new]
           @isolation_issuer.check_reachbility_for_revtr!(outage)

           @logger.debug { "revtr pings issued" }
        end

        outage.measurement_times << ["measurements completed", Time.new]

        # Fetch wether each hop is has been pingable from at least one VP in
        # the past
        fetch_historical_pingability!(outage)

        @logger.debug { "historical pingability fetched" }

        # Issue ground truth measurements (forward path from dst -> src)
        if outage.symmetric
            outage.dst_tr = @isolation_issuer.issue_normal_traceroutes(outage.dst_hostname, outage.src_ip)[outage.src_ip]
            @logger.debug { "destination's tr issued. valid?:#{outage.dst_tr.valid?}" }

            splice_alternate_paths(outage)
            @logger.debug { "alternate path splicing complete" }
        end

	    fempty = @node2emptypings[outage.src].fraction_empty
        if fempty > FailureIsolation::EmptyPingsThreshold
            @logger.info { "scheduling #{outage.src} for swap_out" }
            SwapFilters.empty_pings!(outage, filter_tracker)
        end
    end

    # Convert list of hop objects to list of uniq ip addresses
    def hops_to_uniq_ips(hops)
        Set.new(hops.map { |h| h.ip })
    end

    # One reason measurements might not be issued is that atd is stuck.
    # Restart it
    #
    # TODO: move me into a VP object
    def restart_atd(vp)
        system "ssh uw_revtr2@#{vp} 'sudo /etc/init.d/atd restart > /dev/null 2>&1'"
    end

    # Generate a DOT graph for a given (src, dst) outage 
    # TODO: move me into mkdot.rb
    def generate_jpg(outage)
        # TODO: put this into its own function
        jpg_output = "#{FailureIsolation::DotFiles}/#{outage.log_name}.jpg"

        @dot_generator.generate_jpg(outage, jpg_output)

        jpg_output
    end

    # Place a symlink in the ~/revtr/www directory to put in the href
    def generate_web_symlink(jpg_output)
        t = Time.new
        subdir = "#{t.year}.#{t.month}.#{t.day}"
        abs_path = FailureIsolation::WebDirectory+"/"+subdir
        FileUtils.mkdir_p(abs_path)
        basename = File.basename(jpg_output)
        File.symlink(jpg_output, abs_path+"/#{basename}")
        "http://revtr.cs.washington.edu/isolation_graphs/#{subdir}/#{basename}"
    end

    # Fetch the most recent historical revtr from Dave's database
    # TODO: move me somewhere else
    def fetch_historical_revtr(src,dst)
        @logger.debug { "fetch_historical_revtr(#{src}, #{dst})" }

        dst = dst.ip if dst.is_a?(Hop)

        path = @db.get_cached_reverse_path(src, dst)
        
        # XXX HACKKK. we want to print failed cache fetch reasons in our email. But the email is rendered
        # by iterating over each hop in the historical revtr. So for now, put
        # in the failure reasons as fake "hops". This has actually lead to
        # many problems, and we should instead rener the failure reasons
        # separately 
        #
        # Each x is a failure reason
        path = path.to_s.split("\n").map { |x| ReverseHop.new(x, @ipInfo) } unless path.valid?
        @logger.debug{ "Historical revtr path is #{path}"}

        HistoricalReversePath.new(src, dst, path)
    end

    # retrieve historical forward traceroutes issued from vps (not the atlas)
    # todo: merge this with ethan's pl-pl system -- it's silly to have two.
    # alternatively, grab trace files from the vps more than once a day ;-)
    def retrieve_historical_tr(src, dst)
        src = src.downcase
        if FailureIsolation.Node2Target2Trace.include? src and FailureIsolation.Node2Target2Trace[src].include? dst
            historical_tr_ttlhoptuples = FailureIsolation.Node2Target2Trace[src][dst]
            historical_trace_timestamp = FailureIsolation.HistoricalTraceTimestamp
        else
            @logger.warn { "No historical trace found for #{src},#{dst} ..." }
            historical_tr_ttlhoptuples = []
            historical_trace_timestamp = nil
        end

        @logger.debug { "isolate_outage(#{src}, #{dst}), historical_traceroute_results: #{historical_tr_ttlhoptuples.inspect}" }

        # encapsulate the ttlhoptuple lists into historicalforwardhop objects
        # todoc: why is this a nested array?
        [ForwardPath.new(src, dst, historical_tr_ttlhoptuples.map { |ttlhop| HistoricalForwardHop.new(ttlhop[0], ttlhop[1], @ipInfo) }),
            historical_trace_timestamp]
    end

    # Issue a revtr. Use historical hops for symmetry assumptions optionally. 
    # May be spoofed or not. Default to spoofed. 
    #
    # TODO: generalize to multiple srcs, dsts, 
    #
    # TODO: Copy Dave's email on the agreed upon API here
    def issue_revtr(src, dst, historical_hops=[], spoofed=true)
        # symbol is one of :failed_attempts, :results, :unreachable, or :token
        symbol2srcdst2revtr = {}
        begin
                symbol2srcdst2revtr = (historical_hops.empty?) ? @rtrSvc.get_reverse_paths([[src, dst]]) :
                                                          @rtrSvc.get_reverse_paths([[src, dst]], [historical_hops])
        rescue DRb::DRbConnError => e
            connect_to_drb()
            return SpoofedReversePath.new(src, dst, [:drb_connection_refused])
        rescue java.lang.OutOfMemoryError => e
            raise "OOM here! #{e.backtrace.inspect}"
        rescue Exception, NoMethodError => e
            Emailer.isolation_warning("#{e} \n#{e.backtrace.join("<br />")}").deliver 
            connect_to_drb()
            return SpoofedReversePath.new(src, dst, [:drb_exception])
        rescue Timeout::Error
            return SpoofedReversePath.new(src, dst, [:self_induced_timeout])
        end

        @logger.debug { "isolate_outage(#{src}, #{dst}), symbol2srcdst2revtr: #{symbol2srcdst2revtr.inspect}" }

        # Should never be triggered (assuming Dave's code is upholding the API
        # contract)
        return SpoofedReversePath.new(src, dst, [:unexpected_return_value, symbol2srcdst2revtr]) if symbol2srcdst2revtr.is_a?(Symbol)
        # Sometimes the revtr results can't be serialized by DRB
        raise "issue_revtr returned an #{symbol2srcdst2revtr.class}: #{symbol2srcdst2revtr.inspect}!" if !symbol2srcdst2revtr.is_a?(Hash) and !symbol2srcdst2revtr.is_a?(DRb::DRbObject)

        # Should never be triggered (assuming Dave's code is upholding the API
        # contract)
        if symbol2srcdst2revtr.nil? || symbol2srcdst2revtr.values.find { |hash| hash.include? [src,dst] }.nil?
            return SpoofedReversePath.new(src, dst, [:nil_return_value])
        end

        revtr = [:daves_new_api_is_broken?]

        symbol2srcdst2revtr.each do |symbol,srcdst2revtr|
            case symbol
            when :failed_measurements
                reason = srcdst2revtr[[src,dst]]
                next if reason.nil?
                reason = reason.to_sym if reason.is_a?(String) # dave switched to strings on me...
                revtr = [reason] # TODO: don't encode failure reasons as hops...
            when :results
                string = srcdst2revtr[[src,dst]]
                next if string.nil?
                string= string.get_revtr_string if !string.is_a?(String) 
                revtr = string.split("\n").map { |formatted| ReverseHop.new(formatted, @ipInfo) }
            # The following are for partial results
            # TODO: request partial results for long-lived spoofed revtrs
            when :unreachable
            when :token
            else 
                raise "unknown spoofed_revtr key: #{symbol}"
            end

            @logger.debug { "isolate_outage(#{src}, #{dst}), spoofed_revtr: #{revtr.inspect}" }
        end

        return SpoofedReversePath.new(src, dst, revtr)
    end

    # 2. In the intro, we claim that routing problems where
    # a working policy-compliant path exists, but networks
    # instead route along a different path that fails to deliver
    # packets. are common. It would be nice to
    # have a killer demonstration of this. I.m not positive
    # what it would be, beyond actually making the
    # whole system work and finding the working paths
    # in the case of a failure (this is listed in x5.0.3).
    # Dave suggests that unidirectional failures are such
    # a case. To me, it seems like there could be an issue
    # that kept a link/router from working in only
    # one direction. We are going to investigate splicing
    # together possible paths from 2 known working
    # sub-paths (iPlane-style). Initially, we will investigate
    # this in cases when we control both S and
    # D. For a possible alternate path, we will find the
    # first AS that diverges from the actual path, then
    # identify the ingress router R on that possible path.
    # We will then check if S and D can both ping R. If
    # they can, we will check if the path via R is policycompliant.
    # To generate these detour paths, we can
    # look at the working direction in unidirectional failures,
    # the paths taken by VPs that have connectivity,
    # historical paths from the failing VP, or possibly
    # iPlane predictions. We do not yet have a way to
    # check this if we only control one endpoint. Loose
    # source routing option would do it, but is filtering
    # widely.
    #
    # pre: outage.symmetric == true
    def splice_alternate_paths(outage)
       raise "not a symmetric outage!" unless outage.symmetric

       if outage.direction == Direction.FORWARD
          # TODO: use other data for finding ingresses
          return if outage.tr.empty? # spooftr
          return if outage.historical_tr.empty?
          current_as_path = outage.tr.compressed_as_path  # spooftr?
          old_as_path = outage.historical_tr.compressed_as_path

          divergent_as = Path.first_point_of_divergence(old_as_path, current_as_path)
          return if divergent_as.nil?

          ingress = outage.historical_tr.ingress_router_to_as(divergent_as)
          return if ingress.nil?

          # ping ingress from s and d to reach reachbilitity
          @logger.debug { "splice_alternate_paths() issuing pings" }
          pingable_ips = @isolation_issuer.check_pingability_from_other_vps!([outage.src, outage.dst_hostname], [ingress])
          return unless pingable_ips.include? ingress.ip

          @logger.debug { "splice_alternate_paths() ingress router reachable" }

          src_trace_to_ingress = @isolation_issuer.issue_normal_traceroutes(outage.src, ingress.ip)[ingress.ip]
          @logger.debug { "normal trace: #{src_trace_to_ingress}" }
          return unless src_trace_to_ingress.valid?
          # TODO: normal revtr rather than spoofed
          dst_revtr_from_ingress = issue_revtr(outage.dst_hostname, ingress.ip, [], false)
          @logger.debug { "dst revtr: #{dst_revtr_from_ingress}" }
          return unless dst_revtr_from_ingress.valid?

          outage.spliced_paths << SplicedPath.new(outage.src, outage.dst_hostname, ingress, src_trace_to_ingress, dst_revtr_from_ingress)

          # TODO check if path is policy-compliant
       else
         # src = outage.dst_hostname
         # dst = outage.src_ip
       end
    end

    # Sometimes routers will fail to respond just because they are configured
    # not to respond to ICMP. We issue pings on a regular basis from many VPs
    # to check historial reahability.
    #
    # TODO: Am I giving Ethan all of these hops properly?
    # TODO: move me somewhere else
    def fetch_historical_pingability!(outage)
        all_hop_sets = [outage.historical_tr, outage.spoofed_tr, outage.historical_revtr]

        for hop in outage.historical_tr
            if !(hop.reverse_path.nil?) && hop.reverse_path.valid?
                all_hop_sets << hop.reverse_path 
            end
        end

        all_hop_sets << outage.spoofed_revtr if outage.spoofed_revtr.valid? # might contain a symbol. hmmm... XXX
        all_targets = Set.new
        all_hop_sets.each { |hops| all_targets |= (hops.map { |hop| hop.ip }) }

        ip2lastresponsive = @db.fetch_pingability(all_targets.to_a)

        @logger.debug { "fetch_historical_pingability(), ip2lastresponsive #{ip2lastresponsive.inspect}" }

        # update historical reachability
        all_hop_sets.each do |hop_set|
            hop_set.each { |hop| hop.last_responsive = ip2lastresponsive[hop.ip] }
        end
    end

    # see outage.rb
    def log_srcdst_outage(outage)
        @outage_store.transaction do
            @outage_store[outage.time] = { :id => outage.id,
                                           :outage => Marshal.dump(outage) } 
        end
    end

    # see outage.rb
    def log_merged_outage(merged_outage)
        t = Time.new.to_i
        @merged_outage_store.transaction do
            @merged_outage_store[t] = { :id => merged_outage.id,
                                        :merged_outage => merged_outage.marshal() } 
        end
    end

    # Log filter statistics
    def log_filter_trackers(srcdst2filter_tracker)
        t = Time.new.to_i

        @filter_store.transaction do
          # We assign a unique id for each of today's filter stat objects
          # For now, we use t+src+dst
          srcdst2filter_tracker.each do |srcdst, filter_tracker|
            id = @filter_store.generate_unique_id 
            @filter_store[t] = { :id => id,
                                 :filter_stats => Marshal.dump(filter_tracker) }
          end
        end
    end
end

class EmptyStats 
	def initialize(history_size)
		@empty = 0
		@array = Array.new
		@histsz = history_size
        @mutex = Mutex.new
	end
	def push_empty
        @mutex.synchronize do
            @empty += 1
            @array.push(1)
            self._check_size
        end
	end
	def push_nonempty
        @mutex.synchronize do
            @array.push(0)
            self._check_size
        end
	end
	def fraction_empty
        @mutex.synchronize do
            return @empty.to_f / @array.length
        end
	end
	def _check_size
		while(@array.length > @histsz)
			@empty -= @array.shift
		end
	end
end

if $TEST_THREADS
    foo = lambda do
    while true
        puts "Foo!"
        sleep 1
    end
end
    thread = $executor.submit(&foo)
    puts #{TimeUnit.values.inspect}  
    java_import java.util.concurrent.TimeUnit
                  thread.get(5*1000, TimeUnit::MILLISECONDS) 
                  thread.cancel(true) # should do nothing if done, but needs to happen to free up threads otherwise
    

end

if $0 == __FILE__
    FailureDispatcher.new
end

