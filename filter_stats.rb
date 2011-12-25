require 'thread'
require 'forwardable'

class FilterTracker
   # Per (src, dst) pair filter statistics. Bundles first level, registration,
   # and second level filters together
   
   attr_accessor :source, :target, :connected, :registered_vps, :failure_reasons,
                 :first_lvl_filter_time, :registration_filter_time, :measurement_start_time,
                 :end_time

   alias :src :source
   alias :dst :target
   alias :receivers :connected

   def initialize(source, target, connected, first_lvl_filter_time)
       @source = source
       @target = target
       @connected = connected
       @first_lvl_filter_time = first_lvl_filter_time
       @failure_reasons = []
       @registered_vps = []
   end

   def passed?()
       @failure_reasons.empty?
   end
end
