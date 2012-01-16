#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'
require 'yaml'

datasets = Hash.new(0)
passed_datasets = Hash.new(0)

ases = Hash.new(0)
tiers = Hash.new

tier_count = Hash.new(Range.new(0,0))

class Tier
    attr_accessor :name, :rank

    include Comparable

    def initialize(name)
        @name = name
        case name
        when "stub"
            @rank = 0
        when "smallISP"
            @rank = 1
        when "largeISP"
            @rank = 2
        when "tier1"
            @rank = 3
        else
            raise "unknown rank!"
        end
    end

    def <=>(other)
        @rank <=> other.rank    
    end
end

class Range
    # If we know for sure who the AS is, increment both upper and lower
    def shift()
        Range.new(self.begin + 1, self.end + 1)
    end

    # If we don't know who the AS is, only increment upper (for both tiers)
    def increment_upper
        Range.new(self.begin, self.end + 1)
    end
end

tier_count_filter = Range.new(0,0)
# format is:
# asn tier x y x
File.foreach("ases.20100529") do |line|
    split = line.chomp.split
    tiers[split[0]] = [split[1]]
end

filtered_asns = [3356,3549,1239,1299,174,6453,701,6762,702,7018,7922,2914,3257,10310,12956,7473,209,3320,3491,7474]

paths = []
LogIterator::iterate do  |outage|
    #puts outage.file
    datasets[outage.dataset] += 1       

    if outage.passed_filters
       passed_datasets[outage.dataset] += 1
       #puts outage.to_yaml
       if !outage.suspected_failure.nil? and !outage.suspected_failure.asn.nil?
            other_as = !outage.suspected_failures.nil? and outage.suspected_failures.length>0 
            this_as = outage.suspected_failure.asn
		paths << [outage.src, outage.dst, this_as]
	if other_as

        outage.suspected_failures.each{|fail|
            puts "Fail: #{fail}"
            paths << [outage.src, outage.dst, fail]
        }

            end
       end
    end
end

puts datasets.inspect
puts passed_datasets.inspect

File.open("as_failure_locations.txt", "w+"){|f|
	paths.each{|path|
		f.puts path.join(" ")
	}
}

puts "Filtered ASNs: " + tier_count_filter.inspect

puts tier_count.inspect
