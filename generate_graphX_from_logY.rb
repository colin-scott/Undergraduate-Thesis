#!/homes/network/revtr/ruby/bin/ruby

require 'mkdot'
require 'log_iterator'

if ARGV.size != 2
    $stderr.puts "Usage: #{$0} <jpg output> <log file>"
    exit
end

output, log = ARGV

# XXX deal with previous formats
if log =~ /symmetric/
    LogIterator::read_sym_log(log) do |file, src, dst, dataset, direction, formatted_connected,
           formatted_unconnected, pings_towards_src, tr, spoofed_tr, dst_tr, dst_spoofed_tr,
           historic_tr, historical_trace_timestamp,
           revtr, historic_revtr, testing|

        Dot::generate_jpg(src, dst, direction, dataset, tr, spoofed_tr, historic_tr, revtr, historic_revtr, output)
    end
else
    LogIterator::read_log(log) do |file, src, dst, dataset, direction, formatted_connected, formatted_unconnected,
                         pings_towards_src, tr,
                         spoofed_tr, historic_tr, historical_trace_timestamp,
                         revtr, historic_revtr, testing|
    
        Dot::generate_jpg(src, dst, direction, dataset, tr, spoofed_tr, historic_tr, revtr, historic_revtr, output)
    end
end
