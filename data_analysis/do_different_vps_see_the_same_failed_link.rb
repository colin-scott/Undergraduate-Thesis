#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'
require 'time'
require 'data_analysis'

class Hash
    # could use a BinaryTree, but whatevah
    def sorted_iteration(&block)
        self.keys.sort.each { |k| yield k, self[k] }
    end
end

# given a bucket size in seconds, return a hash from bucket start time to
# outages seen in that bucket
def bucket_outages_by_time(window=20*60)
    outages = []

    LogIterator::iterate do |outage|
        next unless outage.passed_filters
        next unless outage.time.is_a?(Time)
        next if outage.suspected_failure.nil?
     
        outages << outage
    end

    bucket2outages = Hash.new { |h,k| h[k] = [] }

    sorted_outages = outages.sort_by { |o| o.time }

    first_time = sorted_outages[0].time
    next_time = first_time + window

    while !sorted_outages.empty?
        while !sorted_outages.empty? and sorted_outages[0].time < next_time
            bucket2outages[first_time] << sorted_outages.shift
        end
        first_time = next_time
        next_time += window
    end

    bucket2outages
end


bucket2outages = bucket_outages_by_time(40*60)

File.open("bucketed_outages.yml", "w") { |f| YAML.dump(bucket2outages, f) }

#bucket2outages = Marshal.load(File.open("bucketed_outage.bin"))

puts bucket2outages.keys.sort.inspect

total_multiple_source_outages = 0
total_same = 0

bucket2outages.each do |bucket, outages|
    destinations2outages = outages.categorize { |outage| outage.dst }
    multiple_source_outages = destinations2outages.values.find_all { |bucket| bucket.size > 1 }
    next if multiple_source_outages.empty?

    total_multiple_source_outages += multiple_source_outages.size

    multiple_source_outages.each do |outages|
        total_same += 1 if outages.map { |o| o.suspected_failure.asn }.find_all { |asn| !asn.nil?}.uniq.size == 1
#=======
#bucketdsttime2failure.each do |dsttime, failures|
#    if failures.size > 1
#        puts "dsttime: #{dsttime.inspect} num failures: #{failures.size}, uniq failures: #{failures.uniq.size}"
#=======
#
##bucket2outages = bucket_outages_by_time(40*60)
#
##File.open("bucketed_outages.yml", "w") { |f| YAML.dump(bucket2outages, f) }
#
#bucket2outages = Marshal.load(File.open("bucketed_outage.bin"))
#
#puts bucket2outages.keys.sort.inspect
#
#total_multiple_source_outages = 0
#total_same = 0
#
#bucket2outages.each do |bucket, outages|
#    destinations2outages = outages.categorize { |outage| outage.dst }
#    multiple_source_outages = destinations2outages.values.find_all { |bucket| bucket.size > 1 }
#    next if multiple_source_outages.empty?
#
#    total_multiple_source_outages += multiple_source_outages.size
#
#    multiple_source_outages.each do |outages|
#        total_same += 1 if outages.map { |o| o.suspected_failure.asn }.find_all { |asn| !asn.nil?}.uniq.size == 1
#>>>>>>> .r423
#>>>>>>> .r286
    end
end

puts total_multiple_source_outages
puts total_same
