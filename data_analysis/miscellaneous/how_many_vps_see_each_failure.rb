#!/usr/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'
require 'time'
require 'data_analysis'

# Not sure if I need this or not so I'll leave it here anyway : \
class Hash
    # could use a BinaryTree, but whatevah
    def sorted_iteration(&block)
        self.keys.sort.each { |k| yield k, self[k] }
    end
end

#bucket2outages = bucket_outages_by_time(40*60)

#File.open("bucketed_outages.yml", "w") { |f| YAML.dump(bucket2outages, f) }

#bucket2outages = Marshal.load(File.open("bucketed_outage.bin"))

bucket2outages = YAML::load( File.open( 'bucketed_outages.yml' ) )

#puts bucket2outages.keys.sort.inspect

outages2count = Hash.new(0)
# Number of destinations in the database that have become unreachable at one point (for finding the average)
total_distinct_outages = 0
# Number of vp-destination paths that were broken (for finding the average)
total_failed_paths = 0

bucket2outages.each do |bucket, outages|
    # Create a hash of destination to destination-source outage pairs
    destinations2outages = outages.categorize { |outage| outage.dst }
    
    # Count how many vps each outage was seen by by finding the number of "outages" that destiantion has:
    destinations2outages.each do |dst, out|
        outages2count[out.length] += 1
        total_failed_paths += out.length
        total_distinct_outages += 1        
    end
end

# Calculate mean
average_vps_per_outage = (total_failed_paths.to_f / total_distinct_outages.to_f)

# Calculate standard deviation
sum = 0.0
outages2count.each do |vps, outages|
    sum += ((vps - average_vps_per_outage)**2) * (outages)
end
std_dev = (sum / total_failed_paths.to_f)**(0.5)

puts
puts "#{total_distinct_outages} distinct outages with #{total_failed_paths} failed paths total"
puts "Average (vps/outage): #{average_vps_per_outage}"
puts "Standard deviation: #{std_dev}"
puts "Breakdown:"

# Breakdown
(1..outages2count.keys.sort.last).each do |outages|
    puts "#{outages}: #{outages2count[outages]}"
end

puts

