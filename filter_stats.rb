require 'thread'
require 'forwardable'

class FirstLevelFilterTracker
   attr_accessor :target, :initial_observing, :initial_connected, :failure_reasons, :time

   def initialize(target, initial_observing, initial_connected, failure_reasons, time)
        @target = target
        @initial_observing = initial_observing
        @initial_connected = initial_connected
        @failure_reasons = failure_reasons
        @time = time
   end 

   # for threading
   def passed?()
       # if any are true, then a trigger went off
       !@failure_reasons.values.reduce(:|)
   end
end

class RegistrationFilterList
   attr_accessor :time, :registered_vps, :filter_trackers

   # delegate methods to filter_trackers!!!
   extend Forwardable
   def_delegators :@filter_trackers,:&,:*,:+,:-,:<<,:<=>,:[],:[],:[]=,:abbrev,:assoc,:at,:clear,:collect,
       :collect!,:compact,:compact!,:concat,:delete,:delete_at,:delete_if,:each,:each_index,
       :empty?,:fetch,:fill,:first,:flatten,:flatten!,:hash,:include?,:index,:indexes,:indices,
       :initialize_copy,:insert,:join,:last,:length,:map,:map!,:nitems,:pack,:pop,:push,:rassoc,
       :reject,:reject!,:replace,:reverse,:reverse!,:reverse_each,:rindex,:select,:shift,:size,
       :slice,:slice!,:sort,:sort!,:to_a,:to_ary,:transpose,:uniq,:uniq!,:unshift,:values_at,:zip,
       :|,:all?,:any?,:collect,:detect,:each_cons,:each_slice,:each_with_index,:entries,:enum_cons,
       :enum_slice,:enum_with_index,:find_all,:grep,:include?,:inject,:map,:max,:member?,:min,
       :partition,:reject,:select,:sort,:sort_by,:to_a,:to_set


    def initialize(time, registered_vps, filter_trackers=[])
        @time = time
        @registered_vps = registered_vps
        @filter_trackers = filter_trackers
    end
end

class RegistrationFilterTracker
    attr_accessor :outage, :failure_reasons
    
    def initialize(outage, failure_reasons=[])
        @outage = outage 
        @failure_reasons = failure_reasons
    end

    def passed?()
        @failure_reasons.empty?
    end
end


# Which VPs initially passed filtering heuristics, and which passed the final set of filtering heuristics?
# helps us correlate across outages, VPs
class SecondLevelFilterTracker
   attr_accessor :target, :initial_observing, :initial_connected, :final_passed, :final_failed2reasons, :start_time, :end_time

   def initialize(target, initial_observing, initial_connected)
        @target = target
        @initial_observing = initial_observing
        @initial_connected = initial_connected

        @final_passed = []
        @final_failed2reasons = {}

        @start_time = Time.now
   end 

   # for threading
   def complete?()
        @final_passed.size + @final_failed2reasons.size == @initial_observing.size
   end
end

# class alias, for backwards compatiblity
OutageCorrelation = SecondLevelFilterTracker 
