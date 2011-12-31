#!/homes/network/revtr/ruby-upgrade/bin/ruby

# Module for iterating over isolation logs. 
#
# TODO: This code is really terrible. Most of it isn't even used anymore, and
# should be removed
#
# See data_analysis/** for example usage

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

# REV4 is :the only one that matters! everything else has been converted!

# Write a conversion script!!!

# HMMMMMMMM, wouldn't protobufs have been nice :P
# Gotta love versioning

module LogIterator
#    IPINFO = IpInfo.new # hmmm
    #

    def LogIterator::jpg2yml_rev4(jpg)
       FailureIsolation::IsolationResults+"/"+File.basename(jpg).gsub(/jpg$/, "yml")
    end

    def LogIterator::jpg2yml_rev3(jpg)
       FailureIsolation.PreviousIsolationResults+"/"+File.basename(jpg).gsub(/jpg$/, "yml")
    end

    def LogIterator::jpg2yml_rev2(jpg)
       FailureIsolation.LastIsolationResults+"/"+File.basename(jpg).gsub(/jpg$/, "yml")
    end

    def LogIterator::jpg2yml_rev1(jpg)
       FailureIsolation.OlderIsolationResults+"/"+File.basename(jpg).gsub(/jpg$/, "yml")
    end

    def LogIterator::yml2jpg(yml)
        FailureIsolation::DotFiles+"/"+File.basename(yml).gsub(/yml$/, "jpg")
    end

    def LogIterator::all_filtered_outages_rev4(&block)
        Dir.glob(FailureIsolation::DotFiles+"/*jpg").each do |jpg|
            yml = LogIterator::jpg2yml_rev4(jpg)
            begin 
                self.read_log_rev4(yml, &block)
            rescue Errno::ENOENT, ArgumentError, TypeError
                $stderr.puts "failed to open #{yml}, #{$!}"
            end
        end
    end

    def LogIterator::all_filtered_outages_rev3(&block)
        Dir.glob(FailureIsolation::DotFiles+"/*jpg").each do |jpg|
            yml = LogIterator::jpg2yml_rev3(jpg)
            begin 
                self.read_log_rev3(yml, &block)
            rescue Errno::ENOENT, ArgumentError, TypeError
                $stderr.puts "failed to open #{yml}, #{$!}"
            end
        end
    end

    def LogIterator::all_filtered_outages_rev2(&block)
        Dir.glob(FailureIsolation::DotFiles+"/*jpg").each do |jpg|
            yml = LogIterator::jpg2yml_rev2(jpg)
            begin 
                self.read_log_rev2(yml, &block)
            rescue Errno::ENOENT, ArgumentError, TypeError
                $stderr.puts "failed to open #{yml}, #{$!}"
            end
        end
    end

    def LogIterator::all_filtered_outages_rev1(&block)
        Dir.glob(FailureIsolation::DotFiles+"/*jpg").each do |jpg|
            yml = LogIterator::jpg2yml_rev1(jpg)
            begin 
                self.read_log_rev1(yml, &block)
            rescue Errno::ENOENT, ArgumentError, TypeError
                $stderr.puts "failed to open #{yml}, #{$!}"
            end
        end
    end

    def LogIterator::convert(filename)
        bin = filename.gsub(/yml$/, "bin")
        return if File.exists? bin
        arr = YAML.load_file(filename)
        return if !arr || arr.empty? 
        tmp = File.new(bin, "w")
        Marshal.dump(arr, tmp)
        tmp.close
    end

    def LogIterator::convert_all()
        Dir.chdir FailureIsolation::IsolationResults do
            files = Dir.glob("*yml").sort
            total = files.size
            curr = 0
            files.each do |file|
                begin
                    curr += 1
                    self.convert(file)
                rescue Errno::ENOENT, ArgumentError, TypeError
                    $stderr.puts "failed to open #{file}, #{$!} #{$!.backtrace}"
                end
            end
        end
    end

    def LogIterator::convert_and_migrate_symmetric(filename)
        bin = FailureIsolation::Snapshot+"/"+filename.gsub(/yml$/, "bin")
        return if File.exists? bin
        arr = YAML.load_file(filename)
        return if !arr || arr.empty? || arr.include?(nil)
        arr.insert(0, filename)
        tmp = File.new(bin,  "w")
        Marshal.dump(SymmetricOutage.new(*arr), tmp)
        tmp.close
    end

    def LogIterator::convert_and_migrate_symmetric_all()
          Dir.chdir FailureIsolation.SymmetricIsolationResultsFinal do
                files = Dir.glob("*yml").sort
                total = files.size
                files.each do |file|
                    begin
                        $stderr.puts file
                        self.convert_and_migrate_symmetric(file)
                    rescue Errno::ENOENT, ArgumentError, TypeError
                        $stderr.puts "failed to open #{file}, #{$!} #{$!.backtrace}"
                    end
                end
          end
    end

    # HACK! Don't iterate over the snapshot, iterate over all logs
    # STOP COPYING AND PASTING
    def LogIterator::iterate_all_logs(debugging=false, &block)
        Dir.chdir FailureIsolation::IsolationResults do
            files = Dir.glob("*bin").sort
            total = files.size
            curr = 0
            files.each do |file|
                begin
                    curr += 1
                    $stderr.puts file if debugging
                    $stderr.puts (curr * 100.0 / total).to_s + "% complete" if (curr % 50) == 0
                    self.read_log_rev4(file, &block)
                    $stderr.print ".." if debugging
                rescue Errno::ENOENT, ArgumentError, TypeError, EOFError
                    $stderr.puts "failed to open #{file}, #{$!} #{$!.backtrace}"
                end
            end
        end
    end

    def LogIterator::merged_iterate(files=nil, debugging=false, &block)
        Dir.chdir FailureIsolation::MergedIsolationResults do
            files ||= Dir.glob("*bin").sort

            total = files.size
            curr = 0
            files.each do |file|
                begin
                    curr += 1
                    $stderr.puts file if debugging
                    $stderr.puts (curr * 100.0 / total).to_s + "% complete" if (curr % 50) == 0
                    yield Marshal.load(IO.read(file))
                    $stderr.print ".." if debugging
                rescue Errno::ENOENT, ArgumentError, TypeError, EOFError
                    $stderr.puts "failed to open #{file}, #{$!} #{$!.backtrace}"
                end
            end
        end
    end

    # TODO: Change me back to FailureIsolation::IsolationResults?
    def LogIterator::iterate(files=nil, debugging=false, &block)
        Dir.chdir FailureIsolation::Snapshot do
            files ||= Dir.glob("*bin").sort

            total = files.size
            curr = 0
            files.each do |file|
                begin
                    curr += 1
                    $stderr.puts file if debugging
                    $stderr.puts (curr * 100.0 / total).to_s + "% complete" if (curr % 50) == 0
                    self.read_log_rev4(file, &block)
                    $stderr.print ".." if debugging
                rescue Errno::ENOENT, ArgumentError, TypeError, EOFError
                    $stderr.puts "failed to open #{file}, #{$!} #{$!.backtrace}"
                end
            end
        end
    end

    def LogIterator::filter_tracker_iterate(start_date=nil, debugging=false, &block)
        Dir.chdir FailureIsolation::FilterStatsPath do
            files = Dir.glob("*").sort
            if !start_date.nil?
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

    def LogIterator::replace_logs(dispatcher, &block)
        Dir.chdir FailureIsolation::Snapshot do
            files = Dir.glob("*bin").sort
            total = files.size
            curr = 0
            files.each do |file|
                begin
                    curr += 1
                    $stderr.puts (curr * 100.0 / total).to_s + "% complete" if (curr % 50) == 0
                    new_outage = self.read_log_rev4(file, &block)
                    $stderr.puts new_outage.class
                    dispatcher.log_isolation_results(new_outage) if new_outage
                rescue Errno::ENOENT, ArgumentError, TypeError, EOFError
                    $stderr.puts "failed to open #{file}, #{$!} #{$!.backtrace}"
                end
            end
        end
    end

    def LogIterator::iterate_rev1(&block)
        Dir.chdir FailureIsolation.OlderIsolationResults do
            Dir.glob("*yml").each do |file|
                begin
                    self.read_log_rev1(file, &block)
                rescue Errno::ENOENT, ArgumentError, TypeError
                    $stderr.puts "failed to open #{file}, #{$!}"
                end
            end
        end
    end

    def LogIterator::iterate_rev2(&block)
        Dir.chdir FailureIsolation.LastIsolationResults do
            Dir.glob("*yml").each do |file|
                begin
                    self.read_log_rev2(file, &block)
                rescue Errno::ENOENT, ArgumentError, TypeError
                    $stderr.puts "failed to open #{file}, #{$!}"
                end
            end
        end
    end

    def LogIterator::iterate_rev3(&block)
        Dir.chdir FailureIsolation.PreviousIsolationResults do
            Dir.glob("*yml").each do |file|
                begin
                    self.read_log_rev3(file, &block)
                rescue Errno::ENOENT, ArgumentError, TypeError
                    $stderr.puts "failed to open #{file}, #{$!}"
                end
            end
        end
    end

    def LogIterator::symmetric_iterate(&block)
        Dir.chdir FailureIsolation.SymmetricIsolationResultsFinal do
            files = Dir.glob("*yml")
            total = files.size
            curr = 0

            files.each do |file|
                begin
                    curr += 1
                    $stderr.puts (curr * 100.0 / total).to_s + "% complete" if (curr % 50) == 0
                    self.read_sym_log_rev3(file, &block)
                rescue Errno::ENOENT, ArgumentError, TypeError
                    $stderr.puts "failed to open #{file}, #{$!}"
                end
            end
        end
    end

    def LogIterator::symmetric_iterate_rev2(&block)
        Dir.chdir FailureIsolation.OldSymmetricIsolationResults do
            Dir.glob("*yml").each do |file|
                begin
                    self.read_sym_log_rev2(file, &block)
                rescue Errno::ENOENT, ArgumentError, TypeError
                    $stderr.puts "failed to open #{file}, #{$!}"
                end
            end
        end
    end

    def LogIterator::read_log_rev1(file)
        src, dst, dataset, direction, formatted_connected, formatted_unconnected,
               destination_pingable, pings_towards_src, tr,
               spoofed_tr, historical_tr, historical_trace_timestamp,
               spoofed_revtr, historical_revtr, testing = YAML.load_file(file)
        yield file, src, dst, dataset, direction, formatted_connected, formatted_unconnected,
               destination_pingable, pings_towards_src, tr,
               spoofed_tr, historical_tr, historical_trace_timestamp,
               spoofed_revtr, historical_revtr, testing 
    end

    def LogIterator::read_log_rev2(file)
        src, dst, dataset, direction, formatted_connected, formatted_unconnected,
               destination_pingable, pings_towards_src, tr,
               spoofed_tr, historical_tr, historical_trace_timestamp,
               spoofed_revtr, historical_revtr = YAML.load_file(file)
        yield file, src, dst, dataset, direction, formatted_connected, formatted_unconnected,
               destination_pingable, pings_towards_src, tr,
               spoofed_tr, historical_tr, historical_trace_timestamp,
               spoofed_revtr, historical_revtr
    end
 
    def LogIterator::read_log_rev3(file)
        src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr = YAML.load_file(file)
               
        yield file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr
    end
 
    def LogIterator::read_log_rev4(file, &block)
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
               new_outage = yield src
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

    def LogIterator::read_sym_log_rev2(file)
        src, dst, dataset, direction, formatted_connected,
           formatted_unconnected, pings_towards_src,
           tr, spoofed_tr,
           dst_tr, dst_spoofed_tr,
           historical_tr, historical_trace_timestamp,
           spoofed_revtr, historical_revtr, testing = YAML.load_file(file)
               
        yield file, src, dst, dataset, direction, formatted_connected,
           formatted_unconnected, pings_towards_src,
           tr, spoofed_tr,
           dst_tr, dst_spoofed_tr,
           historical_tr, historical_trace_timestamp,
           spoofed_revtr, historical_revtr, testing
    end

    def LogIterator::read_sym_log_rev3(file)
        src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          dst_tr, dst_spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters = YAML.load_file(file)

        yield file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          dst_tr, dst_spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters
    end

    # Start time should be logged... not end time of measurements...
    def LogIterator::parse_time(filename, measurement_times)
        Outage.parse_time(filename, measurement_times)
    end

    def self.parse_correlation_time(filename)
        timestamp = filename.split("_")[-1].split(".")[0]
        year = timestamp[0..3]
        month = timestamp[4..5]
        timestamp = timestamp[6..-1]
        day = timestamp[0..1]
        hour = timestamp[2..3]
        minute = timestamp[4..5]
        second = timestamp[6..7]

        return Time.local(year, month, day, hour, minute, second)
    end
end


if __FILE__ == $0
    #directions = Hash.new(0)

    #LogIterator::iterate() do |file, src, dst, dataset, direction, formatted_connected, formatted_unconnected,
    #                 destination_pingable, pings_towards_src, tr,
    #                 spoofed_tr, historic_tr, historical_trace_timestamp,
    #                 revtr, historic_revtr, testing|
    #    directions[direction] += 1
    #end

    #puts directions.inspect
    
    #LogIterator::read_log_rev3(ARGV.shift) do |file, src, dst, dataset, direction, formatted_connected, 
    #                                      formatted_unconnected, pings_towards_src,
    #                                      tr, spoofed_tr,
    #                                      historical_tr, historical_trace_timestamp,
    #                                      spoofed_revtr, historical_revtr|
    #    Dot::generate_jpg(src, dst, direction, dataset, tr, spoofed_tr,
    #         historical_tr, spoofed_revtr, historical_revtr, "testing.jpg")
    #end
    
    LogIterator::convert_and_migrate_symmetric_all()
end
