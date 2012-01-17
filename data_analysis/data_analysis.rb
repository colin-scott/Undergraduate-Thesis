
class Array
    def categorize()
        categories = Hash.new { |h,k| h[k] = [] }
        self.each { |elt| categories[yield elt] << elt }
        categories
    end
end

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

class Average
    attr_accessor :total, :sum

    def initialize()
        @total = 0
        @sum = 0.0
    end

    def fold_in(val)
        @total += 1
        @sum += val 
    end

    def avg
        avg = (@total == 0) ? 0 : @sum / @total 
    end

    def inspect()
        avg()
    end

    def to_s
       avg()  
    end
end

class MeasurementTimes
    attr_accessor :times 
    def initialize(times)
        @times = times
    end

    def total_duration_seconds
        if @times.empty?
            return -1
        else
            @times[-1][1] - @times[0][1]
        end
    end
end

module Stats
   def self.print_average(name, count, total)
       percent = count*100.0/total
       rounded_percent = ("%.2f" % percent)
       print "#{name}: ".ljust(30)
       print "#{count}".ljust(30)
       print " (#{rounded_percent}%)"
       puts
   end 
end
