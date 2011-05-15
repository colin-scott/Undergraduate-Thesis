#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'

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

# format is:
# asn tier x y x
File.foreach("ases.20100529") do |line|
    split = line.chomp.split
    tiers[split[0]] = [split[1]]
end

LogIterator::iterate do  |outage|
    puts outage.file
    datasets[outage.dataset] += 1       

    if outage.passed_filters
       passed_datasets[outage.dataset] += 1 
       if !outage.suspected_failure.nil? and !outage.suspected_failure.asn.nil?
            other_as = outage.anyone_on_as_boundary?
            this_as = outage.suspected_failure.asn

            if other_as
                this_tier = tiers[this_as]
                other_tier = tiers[other_as]

                if this_tier != other_tier
                    tier_count[this_tier] = tier_count[this_tier].increment_upper
                    tier_count[other_tier] = tier_count[other_tier].increment_upper
                else
                    tier_count[this_tier] = tier_count[this_tier].shift
                end
            else
                tier = tiers[this_as]
                tier_count[tier] = tier_count[tier].shift
            end
       end
    end
end

puts datasets.inspect
puts passed_datasets.inspect

puts tier_count.inspect
