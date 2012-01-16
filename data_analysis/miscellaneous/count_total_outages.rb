#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require 'failure_analyzer'
require 'failure_dispatcher'
require 'log_iterator'
require 'ip_info'
require 'set'

total = 0
passed = 0
directions = Hash.new(0)

# TODO: encapsulate all of these data items into a single object!
LogIterator::iterate do  |o|
    total += 1
    if o.passed_filters
        passed += 1
        directions[o.direction] += 1
   end
end

puts "total: #{total}"
puts "passed: #{passed}"
puts "directions: #{directions.inspect}"

#hist_out.close
#spoof_out.close
#all_out.close
#

spoof_revtr_syms.close

system "scp spoof_revtr_syms.dat cs@toil:~"
