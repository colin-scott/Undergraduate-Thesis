#!/homes/network/revtr/ruby-upgrade/bin/ruby

require 'consts'

# XXX Do we have router data for all peers during the time periods?
#     if not, there's a problem

prefix2sorted_updates = Util.load_prefix2sorted_updates

$stderr.puts "finished loading prefix2sorted_updates"

src_dst2start_ends = Util.load_forward_outages

$stderr.puts "finished loading forward outages"

dst2prefix = Util.load_dst2prefix

$stderr.puts "finished loading dst2prefix"

src_dst2start_ends.each do |src_dst, start_ends|
    src, dst = start_ends
    dst_prefix = dst2prefix[dst]
    sorted_updates = prefix2sorted_updates[dst_prefix]
    
    start_ends.each do |start_time, end_time|
        duration = end_time - start_time

        while !sorted_updates.empty? and sorted_updates.first.time < start_time
            sorted_updates.shift
        end
        
        update_count = 0

        while update_count < sorted_updates.size and sorted_updates[update_count].time < end_time
            update_count += 1
        end
    
        rate = update_count / duration

        puts "#{duration} #{rate}" 
    end
end
