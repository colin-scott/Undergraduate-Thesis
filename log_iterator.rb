#!/homes/network/revtr/ruby/bin/ruby

require 'yaml'
require 'ip_info'
require 'hops'
require 'isolation_module'
require 'set'
require 'time'
require 'outage'

# REV4 is :the only one that matters! everything else has been converted!

# Write a conversion script!!!

# HMMMMMMMM, wouldn't protobufs have been nice :P
# Gotta love versioning

module LogIterator
    IPINFO = IpInfo.new # hmmm

    def LogIterator::jpg2yml_rev4(jpg)
       FailureIsolation::IsolationResults+"/"+File.basename(jpg).gsub(/jpg$/, "yml")
    end

    def LogIterator::jpg2yml_rev3(jpg)
       FailureIsolation::PreviousIsolationResults+"/"+File.basename(jpg).gsub(/jpg$/, "yml")
    end

    def LogIterator::jpg2yml_rev2(jpg)
       FailureIsolation::LastIsolationResults+"/"+File.basename(jpg).gsub(/jpg$/, "yml")
    end

    def LogIterator::jpg2yml_rev1(jpg)
       FailureIsolation::OlderIsolationResults+"/"+File.basename(jpg).gsub(/jpg$/, "yml")
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

    def LogIterator::iterate(debugging=false, &block)
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
                rescue Errno::ENOENT, ArgumentError, TypeError
                    $stderr.puts "failed to open #{file}, #{$!} #{$!.backtrace}"
                end
            end
        end
    end

    def LogIterator::iterate_rev1(&block)
        Dir.chdir FailureIsolation::OlderIsolationResults do
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
        Dir.chdir FailureIsolation::LastIsolationResults do
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
        Dir.chdir FailureIsolation::PreviousIsolationResults do
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
        Dir.chdir FailureIsolation::SymmetricIsolationResultsFinal do
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
        Dir.chdir FailureIsolation::OldSymmetricIsolationResults do
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
        input = File.new(file)
        src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters = Marshal.load(input)

        case block.arity
        when 1
           yield Outage.new(file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters)

        else
           yield file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters
        end
        input.close
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

    def LogIterator::parse_time(filename, measurement_times)
        # heuristic 1: if this was after I started logging measurement times, just 
        # take the timestamp of the first measurement
        if !measurement_times.nil? and !measurement_times.empty?
            return measurement_times[0][1]
        end
    
        # heuristic 2: the file mtimes are correct for isolation_results_rev2
        #    unfortunately the files in isolation_results_rev3 and
        #    isolation_results_rev4 were overwritten, so they all have the same
        #    mtimes
        rev2 = FailureIsolation::LastIsolationResults+"/"+filename
        if File.exists?(rev2)
            f = File.open(rev2, "r")
            mtime = f.mtime
            f.close
            return mtime 
        end
    
        timestamp = filename.split('_')[-1].gsub(/\.yml/, "")
    
        ## heuristic 3: I have .jpgs in the ~/www folder with
        ##      month/day/ subdirectories...
        #jpg = filename.gsub(/yml$/, "jpg")
    
        #if File.exists?(FailureIsolation::WebDirectory+"/"+"1")
        #    return 
        #end
    
        # heuristic 4: guess based on the timestamp
        year = timestamp[0..3]
        # we know that no log is from before Feb. 12th. So it must be a single
        # digit.
        month = timestamp[4..4] 
        days_in_month = (month == "2") ? 28 : 31
    
        timestamp = timestamp[5..-1]
    
        if timestamp.size == "DDHHMMSS".size
           day = timestamp[0..1]
           hour = timestamp[2..3]
           minute = timestamp[4..5]
           second = timestamp[6..7]
        elsif timestamp.size == "DDHHMMSS".size - 1
           # one of them is compressed   
           guesses = LogIterator::infer_one_digit_fields(timestamp, days_in_month)
           #return nil unless guesses.reduce(:|)
           return nil if !guesses[0] || !(guesses[-1] && !guesses[0..-2].reduce(:|))  # if the first field doesn't make sense, it's unambiguous
           day, hour, minute, second = LogIterator::parse_given_single_digit(timestamp, guesses, 1)
        elsif timestamp.size == "DDHHMMSS".size - 2
           # two of them are compressed
           #guesses = infer_one_digit_fields(timestamp, days_in_month)
           return nil # unless guesses.reduce(:|)
        elsif timestamp.size == "DDHHMMSS".size - 3
           # three of them are compressed
           #guesses = infer_one_digit_fields(timestamp, days_in_month)
           return nil # unless guesses.reduce(:|)
        elsif timestamp.size == "DDHHMMSS".size - 4
           # all of them are compressed
           day = timestamp[0..0]
           hour = timestamp[1..1]
           minute = timestamp[2..2]
           second = timestamp[3..3] 
        else
           return nil
        end
    
        #$stderr.puts timestamp
        #$stderr.puts "day: #{day} hour: #{hour} minute: #{minute} second: #{second}"
        return Time.local(year, month, day, hour, minute, second)
    end
    
    def LogIterator::infer_one_digit_fields(timestamp, days_in_month)
        # DDHHMMSS
        day_one = (timestamp[0..1].to_i > days_in_month) 
        hour_one = (timestamp[2..3].to_i >= 60) # || timestamp[2..2] == "0"
        minute_one = (timestamp[4..5].to_i >= 60) # || timestamp[4..4] == "0"
        second_one = (timestamp[6..7].to_i >= 60) # || timestamp[6..6] == "0"
        [day_one, hour_one, minute_one, second_one]
    end
    
    def LogIterator::parse_given_single_digit(timestamp, guesses, num_compressed)
       day_one, hour_one, minute_one, second_one = guesses
       #$stderr.puts guesses.inspect
       if day_one
          return [timestamp[0..0], timestamp[1..2], timestamp[3..4], timestamp[5..6]]
       elsif hour_one
          return [timestamp[0..1], timestamp[2..2], timestamp[3..4], timestamp[5..6]]
       elsif minute_one
          return [timestamp[0..1], timestamp[2..3], timestamp[4..4], timestamp[5..6]]
       elsif second_one
          return [timestamp[0..1], timestamp[2..3], timestamp[4..5], timestamp[6..6]]
       end
    end
end

if __FILE__ == $0
    require 'isolation_module'
    require 'mkdot'

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
    
    LogIterator::convert_all()
end
