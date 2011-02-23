#!/homes/network/revtr/ruby/bin/ruby

require 'yaml'

module LogIterator
    def LogIterator::iterate(&block)
        Dir.chdir FailureIsolation::IsolationResults do
            Dir.glob("*yml").each do |file|
                begin
                self.read_log(file, &block)
                rescue
                end
            end
        end
    end

    def LogIterator::read_log(file)
        src, dst, dataset, direction, formatted_connected, formatted_unconnected,
               destination_pingable, pings_towards_src, tr,
               spoofed_tr, historical_tr_hops, historical_trace_timestamp,
               spoofed_revtr_hops, cached_revtr_hops, testing = YAML.load_file(file)
        yield file, src, dst, dataset, direction, formatted_connected, formatted_unconnected,
               destination_pingable, pings_towards_src, tr,
               spoofed_tr, historical_tr_hops, historical_trace_timestamp,
               spoofed_revtr_hops, cached_revtr_hops, testing 
    end
end

if __FILE__ == $0
    require 'isolation_module'
    require 'mkdot'

    directions = Hash.new(0)

    LogIterator::iterate() do |file, src, dst, dataset, direction, formatted_connected, formatted_unconnected,
                     destination_pingable, pings_towards_src, tr,
                     spoofed_tr, historic_tr, historical_trace_timestamp,
                     revtr, historic_revtr, testing|
        directions[direction] += 1
    end

    puts directions.inspect
end
