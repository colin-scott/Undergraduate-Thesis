#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")
$: << File.expand_path("../../")

require 'data_analysis'
require 'log_iterator'
require 'log_filterer'
require 'set'

missing_spoofed_revtr = 0
missing_historical_revtr = 0
total = 0
missing_spoofed_tr = 0
missing_historical_tr = 0
missing_rtr_pairs = {}


options = OptsParser.new([Predicates.PassedFilters]).parse!.display

LogIterator::iterate_all_logs(options) do  |outage|
    total += 1

    if !outage.historical_revtr.valid? or outage.historical_revtr.empty?
       missing_historical_revtr += 1
       missing_rtr_pairs[[outage.src,outage.dst]] = true
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

File.open("missing_historical_rtr_pairs.txt", "w+"){|f| missing_rtr_pairs.keys.each{|pair| f.puts pair.join(" ")}}
#hist_out.close
#spoof_out.close
#all_out.close

#system "scp historical_sym.out spoof_sym.out all_sym.out cs@toil:~"
