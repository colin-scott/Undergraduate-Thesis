
# There are three levels of filters: 
#   - based on ping state: instable and non-complete outages 
#   - based on VP registration: outages where the relevant VPs aren't registered with the controller
#   - based on isolation measurements: outages which have resolved themselves,
#        or aren't otherwise interesting
#
# Often these filters are too strict or too leniant -> they require a fair
# amount of tweaking. 
#
# This class exists to track staticstics on the filters applied at each level
# to facilitate debugging and tweaking.

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
   alias :time :first_lvl_filter_time

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
