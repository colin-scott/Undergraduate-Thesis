#!/homes/network/revtr/ruby-upgrade/bin/ruby

# Module for iterating over isolation logs. 

$: << "../"

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

# Wouldn't protobufs have been nice :P
# Gotta love versioning

$debugging = false

module LogIterator
    # Iterate over the given log files, with fully specified paths
    def iterate_over_files(files, &block)
        self.iterate(files, FailureIsolation::IsolationResults, self.method(:read_log), &block)
    end

    # Iterate over all src, dst outage logs (not just the snapshot)
    def self.iterate_all_logs(&block)
        self.iterate(nil, FailureIsolation::IsolationResults, self.method(:read_log), &block)
    end

    # Iterate over all src, dst outage logs in the snapshot
    def self.iterate_snapshot(&block)
        self.iterate(nil, FailureIsolation::Snapshot, self.method(:read_log), &block)
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

    # Iterate of logs. By default, just the snapshot
    def self.iterate(files, data_dir, unpack_method, &block)
        Dir.chdir data_dir do
            files ||= Dir.glob("*bin").sort

            total = files.size
            curr = 0
            files.each do |file|
                begin
                    curr += 1
                    $stderr.puts file if $debugging
                    $stderr.puts (curr * 100.0 / total).to_s + "% complete" if (curr % 50) == 0
                    unpack_method.call(file, &block)
                    $stderr.print ".." if $debugging
                rescue Errno::ENOENT, ArgumentError, TypeError, EOFError
                    $stderr.puts "failed to open #{file}, #{$!} #{$!.backtrace}"
                end
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
    
    private

    # Read a single log file
    def self.read_log(file, &block)
        new_outage = nil
        begin
            input = File.new(file)
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
               new_outage = yield outage
            else
               new_outage = yield Outage.new(file, src, dst, dataset, direction, formatted_connected, 
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

        return new_outage
    end
end

module MergedLogIterator
    def self.iterate_over_files(files, &block)
        LogIterator.iterate(files, FailureIsolation::MergedIsolationResults, self.method(:read_log), &block)
    end

    # Iterate over all src, dst outage logs (not just the snapshot)
    def self.iterate_all_logs(&block)
        LogIterator.iterate(nil, FailureIsolation::MergedIsolationResults, self.method(:read_log), &block)
    end

    # TODO: make a separate snapshot dir for merged outages
    
    # TODO: need a replace_logs method

    def self.read_log(file, &block)
        yield Marshal.load(IO.read(file))
    end
end

module FilterTrackerIterator
    def self.filter_tracker_iterate(start_date=nil, &block)
        Dir.chdir FailureIsolation::FilterStatsPath do
            files = Dir.glob("*").sort
            if not start_date.nil?
                start_date_str = start_date.strftime("%Y.%m.%d")
                files.delete_if { |file| file < start_date_str }
            end

            total = files.size
            files.each do |file|
                $stderr.puts "Processing #{file}"

                stats = []
                store = PStore.new(file)
                store.transaction(true) do
                    store.roots.each do |key|
                        stats << store[key]
                    end
                end
                stats.each { |stat| yield stat }
            end
        end
    end
end

