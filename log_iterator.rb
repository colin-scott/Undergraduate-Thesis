#!/homes/network/revtr/ruby/bin/ruby

require 'yaml'
require 'ip_info'
require 'hops'

module LogIterator
    IPINFO = IpInfo.new # hmmm

    def LogIterator::display_results(src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr)
        puts "Source: #{src}"
        puts "Destination: #{IPINFO.format(dst)}"
        puts "Dataset: #{dataset}"
        puts "Direction: #{direction}"
       # puts "Nodes with connectivity: #{formatted_connected.join ','}"
       # puts "Nodes [time since
       # puts "Succesful spoofers: #{pings_towards_src.join ','}"
       # puts "Normal tr: #{tr.inspect}"
       # puts "Spoofed tr: #{spoofed_tr.inspect}"
       # puts "Historical tr: #{historical_tr.inspect}"
       # puts "Spoofed revtr: #{spoofed_revtr.inspect}"
       # puts "Historical revtr: #{historical_revtr.inspect}"
    end

    def LogIterator::jpg2yml(jpg)
       FailureIsolation::IsolationResults+"/"+File.basename(jpg).gsub(/jpg$/, "yml")
    end

    def LogIterator::yml2jpg(yml)
        FailureIsolation::DotFiles+"/"+File.basename(yml).gsub(/yml$/, "jpg")
    end

    def LogIterator::all_filtered_outages(&block)
        Dir.glob(FailureIsolation::DotFiles+"/*jpg").each do |jpg|
            yml = LogIterator::jpg2yml(jpg)
            begin 
                self.read_log_rev3(yml, &block)
            rescue Errno::ENOENT, ArgumentError, TypeError
                $stderr.puts "failed to open #{yml}, #{$!}"
            end
        end
    end

    def LogIterator::iterate(&block)
        Dir.chdir FailureIsolation::IsolationResults do
            Dir.glob("*yml").each do |file|
                begin
                    self.read_log_rev3(file, &block)
                rescue Errno::ENOENT, ArgumentError, TypeError
                    $stderr.puts "failed to open #{file}, #{$!}"
                end
            end
        end
    end

    def LogIterator::read_log_rev1(file)
        src, dst, dataset, direction, formatted_connected, formatted_unconnected,
               destination_pingable, pings_towards_src, tr,
               spoofed_tr, historical_tr_hops, historical_trace_timestamp,
               spoofed_revtr_hops, cached_revtr_hops, testing = YAML.load_file(file)
        yield file, src, dst, dataset, direction, formatted_connected, formatted_unconnected,
               destination_pingable, pings_towards_src, tr,
               spoofed_tr, historical_tr_hops, historical_trace_timestamp,
               spoofed_revtr_hops, cached_revtr_hops, testing 
    end

    def LogIterator::read_log_rev2(file)
        src, dst, dataset, direction, formatted_connected, formatted_unconnected,
               pings_towards_src, tr,
               spoofed_tr, historical_tr_hops, historical_trace_timestamp,
               spoofed_revtr_hops, cached_revtr_hops, testing = YAML.load_file(file)
        yield file, src, dst, dataset, direction, formatted_connected, formatted_unconnected,
               pings_towards_src, tr,
               spoofed_tr, historical_tr_hops, historical_trace_timestamp,
               spoofed_revtr_hops, cached_revtr_hops, testing 
    end
 
    def LogIterator::read_log_rev3(file)
        src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr_hops, historical_trace_timestamp,
                                          spoofed_revtr_hops, cached_revtr_hops = YAML.load_file(file)
               
        yield file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr_hops, historical_trace_timestamp,
                                          spoofed_revtr_hops, cached_revtr_hops
    end

    def LogIterator::read_sym_log(file)
        src, dst, dataset, direction, formatted_connected,
           formatted_unconnected, pings_towards_src,
           tr, spoofed_tr,
           dst_tr, dst_spoofed_tr,
           historical_tr_hops, historical_trace_timestamp,
           spoofed_revtr_hops, cached_revtr_hops, testing = YAML.load_file(file)
               
        yield file, src, dst, dataset, direction, formatted_connected,
           formatted_unconnected, pings_towards_src,
           tr, spoofed_tr,
           dst_tr, dst_spoofed_tr,
           historical_tr_hops, historical_trace_timestamp,
           spoofed_revtr_hops, cached_revtr_hops, testing
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
    
    LogIterator::read_log_rev3(ARGV.shift) do |file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          historical_tr_hops, historical_trace_timestamp,
                                          spoofed_revtr_hops, cached_revtr_hops|
        Dot::generate_jpg(src, dst, direction, dataset, tr, spoofed_tr,
             historical_tr_hops, spoofed_revtr_hops, cached_revtr_hops, "testing.jpg")
    end
end
