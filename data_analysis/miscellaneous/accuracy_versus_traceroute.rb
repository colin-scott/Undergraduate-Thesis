#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../../")
$: << File.expand_path("../")

require 'failure_analyzer.rb'
require 'failure_dispatcher.rb'
require 'log_iterator.rb'
require 'ip_info.rb'
require 'set'

we_win = 0
total = 0
we_win_as = 0

LogIterator::iterate do  |o|
    next unless o.passed_filters
    next unless o.tr.valid?
    
    total += 1

    tr_suspect = o.tr.last_non_zero_hop

    if tr_suspect.nil?
        puts o.tr.inspect
        next
    end

    we_win += 1 unless o.suspected_failure.adjacent?(tr_suspect.ip)
    we_win_as += 1 if tr_suspect.asn != o.suspected_failure.asn
end

puts "we_win: #{we_win}"
puts "we_win_as: #{we_win_as}"
puts total
