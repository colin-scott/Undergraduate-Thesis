#!/homes/network/revtr/ruby-upgrade/bin/ruby

$: << "/homes/network/revtr/spoofed_traceroute/reverse_traceroute"

# Module for iterating over isolation logs. 

require 'rubygems'
require 'rufus/tokyo'
require 'fileutils'
require 'yaml'
require 'ip_info'
require 'hops'
require 'isolation_module'
require 'set'
require 'time'
require 'filter_stats'
require 'outage'
require 'direction'
require 'failure_isolation_consts'
require 'time'
require 'pstore'
require 'thread'

# Wouldn't protobufs have been nice :P
# Gotta love versioning

if RUBY_PLATFORM == "java"
    require 'java'
    java_import java.util.concurrent.Executors
    # TODO: HACK. Make me a platform-independant class variable
    $executor = Executors.newFixedThreadPool(32)
end

$debugging = false

module LogIterator
    # Iterate over the given log files, with fully specified paths
    # Takes a block with outage as arg
    def iterate_over_files(predicates, files, &block)
        self.iterate(predicates, files, FailureIsolation::IsolationResults, self.method(:read_log), &block)
    end

    # Iterate over all src, dst outage logs (not just the snapshot)
    # Takes a block with outage as arg
    def self.iterate_all_logs(predicates, &block)
        # TODO: get rid of nil arg. Use an options hash instead
        self.iterate(predicates, nil, FailureIsolation::IsolationResults, self.method(:read_log), &block)
    end

    # Iterate over all src, dst outage logs in the snapshot
    # Takes a block with outage as arg
    def self.iterate_snapshot(predicates, &block)
        # TODO: get rid of nil arg. Use an options hash instead
        self.iterate(predicates, nil, FailureIsolation::Snapshot, self.method(:read_log), &block)
    end

    # Iterate over all src, dst outages, and invoke the block on it. The block
    # must return another outage object which may have been modified (useful
    # for ensuring backwards compatibility of old log entries). Overwrite the
    # log entry with the new one, using dispatcher.log_outage()
    def self.replace_logs(dispatcher, &block)
        # We need a wrapper block to ensure that the input file is closed before we
        # open the output file
        #block_wrapper = lambda(log_file, &nop_block) do
        #    # Yay for closures: call wth original &block arg
        #    new_outage = self.read_log(log_file, &block)
        #    dispatcher.log_isolation_results(new_outage) if new_outage
        #end

        ## Silly that we need the nop lambda at the end...
        #self.iterate(nil, FailureIsolation::IsolationResults, block_wrapper, lambda)
    end

    # Iterate over logs.
    def self.iterate(predicates, files, data_dir, unpack_method)
        threads = []

        Dir.chdir data_dir do
            files ||= Dir.glob(Dir.pwd+"/*bin").sort
            lock = Mutex.new

            total = files.size
            print_interval = (0.01 * total).to_i + 1
            curr = 0
            files.each do |file|
                block = lambda do
                    begin
                        curr += 1
                        $stderr.puts file if $debugging
                        if (curr % print_interval) == 0
                            percentage = curr * 100.0 / total
                            $stderr.puts percentage.to_s + "% complete" 
                        end
                        outage = unpack_method.call(file)
                        next unless predicates.passes_predicates?(outage)
                        lock.synchronize { yield outage }
                        $stderr.print ".." if $debugging
                    rescue EOFError #Errno::ENOENT, ArgumentError, TypeError 
                        $stderr.puts "failed to open #{file}, #{$!} #{$!.backtrace}"
                    rescue Errno::ENOENT
                        $stderr.puts "#{file} #{$!}"
                    end
                end

                if $executor
                    threads << $executor.submit(&block)
                else
                    block.call
                end
            end
        end

        threads.each do |thread|
            begin
                thread.get
            rescue Exception => e
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
            end
        end
    end

    # Copy all log entries up to now to the snapshot directory (for consistent
    # data analysis)
    def self.take_snapshot
        # TODO: take an end_time arg?
        # Note that Dir.glob yields full pathnames
        FileUtils.cp(Dir.glob(FailureIsolation::IsolationResults+"/*"),  FailureIsolation::Snapshot)
    end
    
    #private

    # Read a single log file, and return the unmarshalled outage
    def self.read_log(file)
        new_outage = nil
        begin
            input = File.new(file, "r")
            src, dst, dataset, direction, formatted_connected, 
                                              formatted_unconnected, pings_towards_src,
                                              tr, spoofed_tr,
                                              historical_tr, historical_trace_timestamp,
                                              spoofed_revtr, historical_revtr,
                                              suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                              alternate_paths, measured_working_direction, path_changed,
                                              measurement_times, passed_filters = Marshal.load(input)

            if src.is_a?(Outage) # we changed over to only logging outage objects at some point. BLLARRRGGGHHH
               outage = src
            else
               # This branch is only for backwards compatibility
               outage = Outage.new(file, src, dst, dataset, direction, formatted_connected, 
                                              formatted_unconnected, pings_towards_src,
                                              tr, spoofed_tr,
                                              historical_tr, historical_trace_timestamp,
                                              spoofed_revtr, historical_revtr,
                                              suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                              alternate_paths, measured_working_direction, path_changed,
                                              measurement_times, passed_filters, [])
            end
        ensure
            input.close if input
        end

        # More backwards compatibility...
        outage.file = file
        return outage 
    end
end

module MergedLogIterator
    # Takes a block with outage as arg
    def self.iterate_over_files(predicates, files, &block)
        files = files.map { |f|  FailureIsolation::MergedIsolationResults + "/" + f + ".bin" } 
        LogIterator.iterate(predicates, files, FailureIsolation::MergedIsolationResults, self.method(:read_log), &block)
    end

    # Iterate over all src, dst outage logs (not just the snapshot)
    # Takes a block with outage as arg
    def self.iterate_all_logs(predicates, &block)
        # TODO: get rid of nil arg. Use an options hash instead
        LogIterator.iterate(predicates, nil, FailureIsolation::MergedIsolationResults, self.method(:read_log), &block)
    end

    # TODO: make a separate snapshot dir for merged outages
    
    # TODO: need a replace_logs method

    # Read a single log file, and return the unmarshalled MergedOutage
    def self.read_log(file)
        Marshal.load(IO.read(file))
    end
end

module FilterTrackerIterator
    @@table = nil

    # Takes a block with filter tracker as arg
    def self.iterate(options, &block)
        # http://rufus.rubyforge.org/rufus-tokyo/
        @@table ||= Rufus::Tokyo::Table.new(FailureIsolation::FilterStatsPath,
                                        :mode => 'r')

        result_set = @@table.do_query do |q|
            #     '' denotes primary key
            q.add '', :numge, options[:time_start].to_i
            q.add '', :numle, options[:time_end].to_i
        end
        
        result_set.each do |result_hash|
            stats = result_hash["filter_stats"]
            block.call(stats) if options.passes_predicates? stats
        end
    end
end


if $0 ==  __FILE__ 
    require 'log_filterer'
    options = OptsParser.new
    result_set = FilterTrackerIterator.iterate(options)
    puts result_set.size
    v2 = FilterTrackerIterator.iteratev2(options)
    puts v2.size
    leftovers = (v2.to_a - result_set.to_a)
    if leftovers.size < v2.size
        puts leftovers.inspect
        puts leftovers.size
    end
end
