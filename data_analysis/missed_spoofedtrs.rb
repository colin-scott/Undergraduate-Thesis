#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'data_analysis'
require 'failure_analyzer'
require 'failure_dispatcher'
require 'log_iterator'
require 'ip_info'
require 'set'

missing_spoofed_revtr = 0
missing_historical_revtr = 0
total = 0
missing_spoofed_tr = 0
missing_historical_tr = 0

# TODO: encapsulate all of these data items into a single object!
LogIterator::iterate do  |outage|
    total += 1

    if !outage.historical_revtr.valid? or outage.historical_revtr.empty?
       missing_historical_revtr += 1
    end

    if !outage.spoofed_revtr.valid?
       missing_spoofed_revtr += 1 
    end

    if !outage.spoofed_tr.valid? 
        missing_spoofed_tr += 1
    end

    if !outage.historical_tr.valid?
        missing_historical_tr += 1
    end
end

puts "total #{total}"
Stats::print_average("missing_revtr", missing_spoofed_revtr, total)
Stats::print_average("missing_historical_revtr", missing_historical_revtr, total)
Stats::print_average("missing_spoofed_tr", missing_spoofed_tr, total)
Stats::print_average("missing_historical_tr", missing_historical_tr, total)


#hist_out.close
#spoof_out.close
#all_out.close

#system "scp historical_sym.out spoof_sym.out all_sym.out cs@toil:~"
