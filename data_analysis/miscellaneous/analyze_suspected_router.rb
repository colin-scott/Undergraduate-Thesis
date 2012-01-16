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

total_multiple_source_outages = 0
total_same = 0
total_majority_same = 0

majority_threshold = 0.5

destinations2suspects = Hash.new

bucket2outages.each do |bucket, outages|
    destinations2outages = outages.categorize { |outage| outage.dst }
    multiple_source_outages = destinations2outages.values.find_all { |bucket2| bucket2.size > 1 }
    next if multiple_source_outages.empty?

    total_multiple_source_outages += multiple_source_outages.size

    puts "#{bucket}:"

#    destinations2suspects[bucket] = Hash.new

    multiple_source_outages.each do |outages|
        destination = outages[0].dst
        asn_list = outages.map { |o| o.suspected_failure.asn }.find_all { |asn| !asn.nil?}
#        destinations2suspects[bucket][destination] = Hash.new 
      
        puts "  #{destination}:"
        #puts asn_list

        asn_list.uniq.each do |asn|
            destinations2suspects[bucket] = Hash.new
            destinations2suspects[bucket][destination] = Hash.new
            destinations2suspects[bucket][destination][asn] = asn_list.find_all{ |s| s == asn }.size
            puts "    #{asn}: #{destinations2suspects[bucket][destination][asn]}"
        end 
        
        total_same += 1 if asn_list.uniq.size == 1
    end
end

File.open("destinations2suspects.yml", "w") { |f| YAML.dump(destinations2suspects, f) }

destinations2suspects.keys.each do |outage|
    destinations2suspects[outage].keys.each do |destination|
        total_guesses = 0
        most_likely_guesses = 0
        destinations2suspects[outage][destination].keys.each do |asn|
            guesses = destinations2suspects[outage][destination][asn]
            total_guesses += guesses
            most_likely_guesses = guesses if most_likely_guesses < guesses
        end
        total_majority_same += 1 if most_likely_guesses.to_f/total_guesses.to_f >= majority_threshold
    end
end

puts
puts "Of #{total_multiple_source_outages} multiple-source outages,"
puts "  #{total_same} had all VPs suspect the same ASN"
puts "  #{total_majority_same} had at least #{(majority_threshold*100)}\% of VPs suspect the same ASN"

