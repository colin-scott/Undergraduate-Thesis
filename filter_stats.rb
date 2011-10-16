require 'thread'

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
    attr_accessor :time, :registered_vps, :register_filter_trackers

    def initialize(time, registered_vps, register_filter_trackers=[])
        @time = time
        @registered_vps = registered_vps
        @register_filter_trackers = register_filter_trackers
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
