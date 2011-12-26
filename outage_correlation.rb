require 'thread'

# Which VPs initially passed filtering heuristics, and which passed the final set of filtering heuristics?
# helps us correlate across outages, VPs
class OutageCorrelation
   attr_accessor :target, :initial_observing, :initial_connected, :final_passed, :final_failed2reasons, :start_time, :end_time

   alias :time  :start_time

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
