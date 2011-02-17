#!/homes/network/revtr/ruby/bin/ruby

require 'yaml'

module LogIterator
    def LogIterator::iterate(&block)
        Dir.chdir FailureIsolation::IsolationResults do
            Dir.glob("*yml").each do |file|
                self.read_log(file, &block)
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
    LogIterator::iterate() do |file, src, dst, dataset, direction, formatted_connected, formatted_unconnected,
                     destination_pingable, pings_towards_src, tr,
                     spoofed_tr, historic_tr, historical_trace_timestamp,
                     revtr, historic_revtr, testing|

        dot_output = "#{FailureIsolation::IsolationResults}/#{file.gsub(/yml$/, 'dot')}"

        forward_measurements_empty = (tr.size <= 1 && spoofed_tr.size <= 1)
        if(!testing && !destination_pingable && direction != "both paths seem to be working...?" &&
                !forward_measurements_empty)

           Dot::create_dot_file(direction, dataset, tr, spoofed_tr, historic_tr, revtr, historic_revtr, dot_output)
        end
    end
end
