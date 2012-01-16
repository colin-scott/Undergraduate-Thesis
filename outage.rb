#!/homes/network/revtr/ruby-upgrade/bin/ruby

# Two classes:
#   - Outage: encapsulates all measurement + analytic data for a single (src, dst) outage.
#   - MergedOutage: encapsulates all measurement + analytic data for a set of merged (src, dst) outages.

require 'hops'
require 'set'
require 'failure_analyzer'
require 'failure_isolation_consts'

# What heuristic was used to merge the Outages 
module MergingMethod
    REVERSE = :one_src_multiple_dsts
    FORWARD = :multiple_srcs_one_dst
end

# encapsulates mutiple (src,dst) pairs identified as being related to the same
# failure
class MergedOutage
   attr_accessor :outages, :suspected_failures, :file, :initializer2suspectset, :merging_method,
       # NEW FIELD
       :pruner2incount_removed

   alias :log_name :file

   # Behave as an array of Outages by delegating to @outages
   extend Forwardable
   def_delegators :@outages,:&,:*,:+,:-,:<<,:<=>,:[],:[],:[]=,:abbrev,:assoc,:at,:clear,:collect,
       :collect!,:compact,:compact!,:concat,:delete,:delete_at,:delete_if,:each,:each_index,
       :empty?,:fetch,:fill,:first,:flatten,:flatten!,:hash,:include?,:index,:indexes,:indices,
       :initialize_copy,:insert,:join,:last,:length,:map,:map!,:nitems,:pack,:pop,:push,:rassoc,
       :reject,:reject!,:replace,:reverse,:reverse!,:reverse_each,:rindex,:select,:shift,:size,
       :slice,:slice!,:sort,:sort!,:to_a,:to_ary,:transpose,:uniq,:uniq!,:unshift,:values_at,:zip,
       :|,:all?,:any?,:collect,:detect,:each_cons,:each_slice,:each_with_index,:entries,:enum_cons,
       :enum_slice,:enum_with_index,:find_all,:grep,:include?,:inject,:map,:max,:member?,:min,
       :partition,:reject,:select,:sort,:sort_by,:to_a,:to_set

    def initialize(outages, merging_method=MergingMethod::REVERSE)
        outages.each { |o| raise "Not an outage object!" if !o.is_a?(Outage) }
        @outages = outages
        @suspected_failures = {}
        @initializer2suspectset = {}
        @pruner2incount_removed = {}
        @merging_method = merging_method
    end

    # Convert @pruner2incount_removed to just pruner2removed
    def pruner2removed()
        if @pruner2removed.nil? and !@pruner2incount_removed.nil?
            return @pruner2incount_removed.map_values { |v| v[1] }
        elsif !@pruner2removed.nil?
            return @pruner2removed
        else
            return {}
        end
    end

    # Did at least one (src, dst) outage pass filters?
    def is_interesting?()
        return @outages.find { |outage| outage.passed_filters }
    end

    # Return all outages where the destination was under our control
    def symmetric_outages()
        @outages.find_all { |outage| outage.symmetric }
    end

    # Sloppy notion of "direction" for aggregate outages. If at least one
    # reverse: reverse. Else if at least one forward: forward. Else if no
    # bidirectional: false positive. Else bidirectional.
    def direction()
        return Direction.REVERSE unless @outages.find { |o| o.direction == Direction.REVERSE }.nil?
        return Direction.FORWARD unless @outages.find { |o| o.direction == Direction.FORWARD }.nil?
        return Direction.FALSE_POSITIVE if @outages.find { |o| o.direction == Direction.BOTH }.nil?
        return Direction.BOTH
    end

    # Return the unique datasets (input lists) the destinations were taken from
    def datasets()
        return @outages.map { |o| o.dataset }.uniq
    end

    # Return the unique sources
    def sources()
        return @outages.map { |o| o.src }.uniq
    end

    # Return the unique destinations
    def destinations()
        return @outages.map { |o| o.dst }.uniq
    end

    # Return the time measurements were initiated
    def time()
        return @outages.first.time
    end
end

# Encapsulate all measurement + analytic data for a single (src, dst) outage.
#
# TODO: builder pattern?
# TODO: convert all old SymmetricOutage objects to Outage.symmetric = true
class Outage
  # Note: suspected_failures is now not even a part of Outage objects -- part of
  # MergedOutage objects...
  #
  #    suspected_failures was a hash { :direction => [suspected_failure1, suspected_failure2...] }
  #              hash to account for bidirectional outages
 
  attr_accessor :file, :src, :dst, :dataset, :direction, :connected, :formatted_connected,
                                          :formatted_unconnected, :formatted_never_seen, :pings_towards_src,
                                          :tr, :spoofed_tr,
                                          :dst_tr, :dst_spoofed_tr, :src_ip, :dst_hostname,
                                          :historical_tr, :historical_trace_timestamp,
                                          :spoofed_revtr, :historical_revtr,
                                          # Deprecated
                                          :suspected_failure,
                                          # Deprecated
                                          :suspected_failures,
                                          :as_hops_from_dst, :as_hops_from_src, 
                                          :alternate_paths, :measured_working_direction, :path_changed,
                                          :measurement_times, :passed_filters, 
                                          # miscellaneous measurements +
                                          # analytics
                                          :additional_traces, :upstream_reverse_paths, :category, :symmetric,
                                          :measurements_reissued, :spliced_paths, :jpg_output, :graph_url, :responsive_targets,
                                          :asn_to_poison,
                                          # Whether the historical revtr was
                                          # valid for reverse outages
                                          :complete_reverse_isolation

  alias :revtr :spoofed_revtr
  alias :spoofers :connected 
  alias :spoofers_w_connectivity :connected 
  alias :receivers :connected 
  alias :normal_forward_path :tr
  alias :spoofed_forward_path :spoofed_tr
  alias :historical_forward_path :historical_tr
  alias :historical_fpath_timestamp :historical_trace_timestamp
  alias :source :src 
  alias :dest :dst
  alias :additional_traceroutes :additional_traces 
  alias :log_name :file
  
  def initialize(*args)
        @additional_traces = {}
        @upstream_reverse_paths = {}
        @spliced_paths = []
        @suspected_failures = {}
        @responsive_targets = Set.new
        @measurement_times = []

        case args.size
        when 0
            @src = "test.pl.edu"
            @dst = "1.2.3.4"
            @connected = []
            @formatted_connected = []
            @formatted_unconnected = []
            @formatted_never_seen = []
        when 1 # Keywords
            hash = args[0]
            hash.each do |key, value|
               self.send("#{key}=", value) 
            end
        when 6
            @src, @dst, @connected, @formatted_connected, @formatted_unconnected, @formatted_never_seen = args

            @dataset = FailureIsolation.get_dataset(@dst)

            return
        when 22
            @file, @src, @dst, @dataset, @direction, @formatted_connected, 
                                          @formatted_unconnected, @pings_towards_src,
                                          @tr, @spoofed_tr,
                                          @historical_tr, @historical_trace_timestamp,
                                          @spoofed_revtr, @historical_revtr,
                                          @suspected_failure, @as_hops_from_dst, @as_hops_from_src, 
                                          @alternate_paths, @measured_working_direction, @path_changed,
                                          @measurement_times, @passed_filters = args

        when 23
            @file, @src, @dst, @dataset, @direction, @formatted_connected, 
                                          @formatted_unconnected, @pings_towards_src,
                                          @tr, @spoofed_tr,
                                          @historical_tr, @historical_trace_timestamp,
                                          @spoofed_revtr, @historical_revtr,
                                          @suspected_failure, @as_hops_from_dst, @as_hops_from_src, 
                                          @alternate_paths, @measured_working_direction, @path_changed,
                                          @measurement_times, @passed_filters, @additional_traces = args

        when 24
            @file, @src, @dst, @dataset, @direction, @formatted_connected, 
                                          @formatted_unconnected, @pings_towards_src,
                                          @tr, @spoofed_tr,
                                          @historical_tr, @historical_trace_timestamp,
                                          @spoofed_revtr, @historical_revtr,
                                          @suspected_failure, @as_hops_from_dst, @as_hops_from_src, 
                                          @alternate_paths, @measured_working_direction, @path_changed,
                                          @measurement_times, @passed_filters, @additional_traces,
                                          @upstream_reverse_paths = args
        else
            raise "unknown # of args!"
        end
   
        if @tr.nil? or @spoofed_tr.nil? or @historical_tr.nil? or @spoofed_revtr.nil? or @historical_revtr.nil?
            # Shouldn't happen
            $stderr.puts file
        end

        #@alternate_paths ||= $analyzer.find_alternate_paths(src, dst, direction, tr, spoofed_tr, historical_tr,
        #                              spoofed_revtr, historical_revtr)

        #link_listify!
   end

   # Deprecated
   def dst_as()
   end

   def parse_time
        # heuristic 1: if this was after I started logging measurement times, just 
        # take the timestamp of the first measurement
        if !@measurement_times.nil? and !@measurement_times.empty?
            return @measurement_times[0][1]
        end

        timestamp = @filename.split('_')[-1].split('.')[0]
    
        # heuristic 4: guess based on the timestamp
        year = timestamp[0..3]
        # we know that no log is from before Feb. 12th. So it must be a single
        # digit.
        month = timestamp[4..4] 
        days_in_month = (month == "2") ? 28 : 31
    
        timestamp = timestamp[5..-1]
    
        if timestamp.size == "DDHHMMSS".size
           day = timestamp[0..1]
           hour = timestamp[2..3]
           minute = timestamp[4..5]
           second = timestamp[6..7]
        else
           return nil
        end
    
        return Time.local(year, month, day, hour, minute, second)
   end
  
   # Return the time measurements were initiated for this outage
   def time
        @time = parse_time if @time.nil?
        @time = false if @time.nil? # TODO: need a better way to distinguish nil from "not able to parse time"
        @time
   end

   # Deprecated
   def historical_revtr
       @historical_revtr
   end

   # Return all ping responsive hops for this outage
   def ping_responsive
       ping_responsive = Set.new

       @historical_tr.each do |hop|
           ping_responsive |= hop.reverse_path.find_all { |hop| hop.ping_responsive }.map { |hop| hop.ip } if hop.reverse_path.valid?
       end

       ping_responsive |= @historical_tr.find_all { |hop| hop.ping_responsive }.map { |hop| hop.ip }
       ping_responsive |= @historical_revtr.find_all { |hop| hop.ping_responsive }.map { |hop| hop.ip }
       ping_responsive |= @spoofed_tr.find_all { |hop| hop.ping_responsive }.map { |hop| hop.ip }
       ping_responsive |= @spoofed_revtr.find_all { |hop| hop.ping_responsive }.map { |hop| hop.ip } if spoofed_revtr.valid?

       ping_responsive
   end

   # Return whether the spoofed traceroute follows the same path as the normal
   # traceroute. Shouldn't happen, unless paths changed between the time the
   # normal traceroute and spoofed traceroute were issued.
   #
   # TODO: do we really want this functionality within the Outage class?
   def paths_diverge?
        spoofed_tr_loop = @spoofed_tr.contains_loop?()
        tr_loop = @tr.contains_loop?()

        compressed_spooftr = @spoofed_tr.compressed_prefix_path
        compressed_tr = @tr.compressed_prefix_path
        
        divergence = !Path.share_common_path_prefix?(compressed_spooftr, compressed_tr)

        ## XXX Change $LOG?
        #$LOG.puts "spooftr_loop!(#{@src}, #{@dst}) #{@spoofed_tr.map { |h| h.ip }}" if spoofed_tr_loop
        #$LOG.puts "tr_loop!(#{@src}, #{@dst}) #{@tr.map { |h| h.ip}}" if tr_loop
        #$LOG.puts "divergence!(#{@src}, #{@dst}) #{compressed_spooftr} --tr-- #{compressed_tr}" if divergence

        return spoofed_tr_loop || tr_loop || divergence
   end

   # Return whether the suspected failure is on an AS boundary
   #
   # TODO: do we really want this functionality within the Outage class?
   def anyone_on_as_boundary?()
       return false if @suspected_failure.nil?

       [@tr, @spoofed_tr, @historical_tr, @spoofed_revtr].each do |path|
           same_hop = path.find { |hop| !hop.is_a?(MockHop) && hop.cluster == @suspected_failure.cluster }
           if !same_hop.nil? && same_hop.on_as_boundary?
               return true
           end
       end

       return false
   end

   # Compute the measurement durations between each measurement timestamp
   #
   # given an array of the form:
   #   [[measurement_type, time], ...]
   # Transform it into:
   #   [[measurement_type, time, duration], ... ]
   def insert_measurement_durations
       0.upto(@measurement_times.size - 2) do |i|
           duration = @measurement_times[i+1][1] - @measurement_times[i][1] 
           @measurement_times[i] << "(#{duration} seconds)"
       end
   end

   # get actual duration of all measurements
   def get_measurement_duration
       duration = 0
       0.upto(@measurement_times.size - 2) do |i|
           duration += @measurement_times[i+1][1] - @measurement_times[i][1]
       end
       return duration
   end

   # Our fake builder pattern
   def build()
        insert_measurement_durations
        link_listify!
   end

   # Link Listify all of the enapsulated paths
   #
   # silly YAML doesn't call our constructor directly... so we have to do this
   # by hand
   def link_listify!
       @tr.link_listify!
       @spoofed_tr.link_listify!
       @historical_tr.link_listify!
       @historical_revtr.link_listify!
       @spoofed_revtr.link_listify!
   end

   def passed?
      @passed_filters
   end

   def to_s(verbose=true)
       s = "(#{self.src}, #{self.dst})"
       s << " [passed filters?: #{self.passed_filters}]" if verbose
       s << " {id=#{self.file}.bin}" if verbose
       s
   end

   def to_html()
      ""
   end
end

# DEPRECATED
# Special case of Outage, so subclass
class SymmetricOutage < Outage
end

if $0 == __FILE__
end
