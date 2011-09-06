#!/homes/network/revtr/ruby/bin/ruby
#
require 'hops'
require 'set'
require 'failure_isolation_consts'

# encapsulates mutiple (src,dst) pairs identified as being related to the same
# failure
class MergedOutage
   attr_accessor :outages, :suspected_failures, :file, :initializer2suspectset,
       :pruner2removed

   alias :log_name :file

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

    def initialize(outages)
        outages.each { |o| raise "Not an outage object!" if !o.is_a?(Outage) }
        @outages = outages
        @suspected_failures = {}
    end

    def is_interesting?()
        return !@outages.find { |outage| outage.passed_filters }.nil?
    end

    def symmetric_outages()
        @outages.find_all { |outage| outage.symmetric }
    end

    def direction()
         return Direction.REVERSE unless @outages.find { |o| o.direction == Direction.REVERSE }.nil?
         return Direction.FORWARD unless @outages.find { |o| o.direction == Direction.FORWARD }.nil?
         return Direction.BOTH
    end

    def datasets()
        return @outages.map { |o| o.dataset }.uniq
    end

    def sources()
        return @outages.map { |o| o.src }
    end
end

# TODO: builder pattern?
# TODO: convert all old SymmetricOutage objects to Outage.symmetric = true
class Outage
  # !! suspected_failures is now not even a part of Outage objects -- part of
  # MergedOutage objects...
  #    suspected_failures was a hash { :direction => [suspected_failure1, suspected_failure2...] }
  #              hash to account for bidirectional outages
  attr_accessor :file, :src, :dst, :dataset, :direction, :connected, :formatted_connected,
                                          :formatted_unconnected, :formatted_never_seen, :pings_towards_src,
                                          :tr, :spoofed_tr,
                                          :dst_tr, :dst_spoofed_tr, :src_ip, :dst_hostname,
                                          :historical_tr, :historical_trace_timestamp,
                                          :spoofed_revtr, :historical_revtr,
                                          :suspected_failure, :suspected_failures, :as_hops_from_dst, :as_hops_from_src, 
                                          :alternate_paths, :measured_working_direction, :path_changed,
                                          :measurement_times, :passed_filters, 
                                          :additional_traces, :upstream_reverse_paths, :category, :symmetric,
                                          :measurements_reissued, :spliced_paths, :jpg_output, :graph_url, :responsive_targets

  # re: symmetric
  #   tried to implement symmetry through polymorphism... but no behavior is
  #   changed... only whether additional fields are nil or not
  
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

        case args.size
        when 0
            @src = "test.pl.edu"
            @dst = "1.2.3.4"
            @connected = []
            @formatted_connected = []
            @formatted_unconnected = []
            @formatted_never_seen = []
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
            $stderr.puts file
        end

        #@alternate_paths ||= $analyzer.find_alternate_paths(src, dst, direction, tr, spoofed_tr, historical_tr,
        #                              spoofed_revtr, historical_revtr)

        #link_listify!
   end

   def dst_as()
   end

   def time
        @time = LogIterator::parse_time(@file, @measurement_times) if @time.nil?
        @time = false if @time.nil? # XXX hmmmm
        @time
   end

   def historical_revtr
       @historical_revtr
   end

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

   # XXX do I want functionality within the class???
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

   # XXX do I want functionality within the class???
   def anyone_on_as_boundary?()
       return false if @suspected_failure.nil?

       [@tr, @spoofed_tr, @historical_tr, @spoofed_revtr].each do |path|
           same_hop = path.find { |hop| !hop.is_a?(MockHop) && hop.cluster == @suspected_failure.cluster }
           if !same_hop.nil? && same_hop.on_as_boundary?
               #puts same_hop.asn
               #puts same_hop.previous.asn
               #puts same_hop.next.asn
               return same_hop.on_as_boundary?
           end
       end

       return false
   end

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

   # Our fake builder pattern
   def build()
        insert_measurement_durations
        link_listify!
   end

   # silly YAML doesn't call our constructor directly... so we have to do this
   # by hand
   def link_listify!
       @tr.link_listify!
       @spoofed_tr.link_listify!
       @historical_tr.link_listify!
       @historical_revtr.link_listify!
       @spoofed_revtr.link_listify!
   end

   def to_s()
       ""
   end

   def to_html()
      ""
   end
end

# DEPRECATED
# Special case of Outage, so subclass
class SymmetricOutage < Outage
    def initialize(*args)
        # always the 11th and 12th argument. 
        # Oh god, what a hack...
        #
        #log_name, src, dst, dataset, direction, formatted_connected, 
        #                                  formatted_unconnected, pings_towards_src,
        #                                  tr, spoofed_tr,
        #                                  dst_tr, dst_spoofed_tr,
        #                                  historical_tr, historical_trace_timestamp,
        #                                  spoofed_revtr, historical_revtr,
        #                                  suspected_failure, as_hops_from_dst, as_hops_from_src, 
        #                                  alternate_paths, measured_working_direction, path_changed,
        #                                  measurement_times, passed_filters, additional_traceroutes
        
        @dst_tr = args.delete_at(10)
        @dst_spoofed_tr = args.delete_at(10)
        
        super(*args)
    end
end

if $0 == __FILE__
    SymmetricOutage.new("", "", "", "", "", [], 
                                          [], [],
                                          Path.new, Path.new,
                                          Path.new, Path.new,
                                          Path.new, nil,
                                          Path.new, Path.new,
                                          nil, 0, 0, 
                                          [], false, [],
                                          [], false, {}, {})

end
