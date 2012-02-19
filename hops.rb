#!/homes/network/revtr/ruby-upgrade/bin/ruby

# Classes for encapsulating measurements and convenience data analysis methods
# on the measurement data.


# Note that for all classes below,  last_responsive will be:
#    * "N/A" if not in the database
#    * false if not historically pingable
#    * A Time object if historically pingable
#    * nil if not initialized (not grabbed from the DB yet)


# =============================================================================
#                            Paths                                            #
# =============================================================================

require 'forwardable'
require 'isolation_utilities.rb'

# Generic Path class
class Path
   @@last_hop_sanity_check_distance = 5
   attr_accessor :hops, :src, :dst, :invalid_reason

   def initialize(src, dst, init_hops=[])
      # FOR BACKWARDS COMPATABILITY: init_hops[0] will be a symbol if invalid, so take it out
      # to get rid of valid? problems, but the caller still signals invalidity
      # with init_hops[0]
      
      @src = src
      @dst = dst.strip
      begin 
        if init_hops.is_a?(Path)
            init_hops = init_hops.hops
        elsif !init_hops.is_a?(Array)
            raise "not an Array!: #{init_hops.class} #{init_hops.inspect}" 
        end

        if !init_hops.empty? and init_hops[0].is_a?(Symbol)
            @invalid_reason = init_hops.join ' '
            @hops = []
        else
            @hops = Array.new(init_hops)
        end
        # TODO: link_listify!() ?
      rescue Exception => e
          raise "Caught #{e} #{e.backtrace}, init_hops was #{init_hops.inspect}"
      end

      sanitize_hops!
      canonocalize_hops!
   end

   # delegate methods to @hops!!!
   # This way the Path Objects will serialize properly...
   # subclassing Array does weird things...
   extend Forwardable
   def_delegators :@hops,:&,:*,:+,:-,:<<,:<=>,:[],:[],:[]=,:abbrev,:assoc,:at,:clear,:collect,
       :collect!,:compact,:compact!,:concat,:delete,:delete_at,:delete_if,:each,:each_index,
       :empty?,:fetch,:fill,:first,:flatten,:flatten!,:hash,:include?,:index,:indexes,:indices,
       :initialize_copy,:insert,:join,:last,:length,:map,:map!,:nitems,:pack,:pop,:push,:rassoc,
       :reject,:reject!,:replace,:reverse,:reverse!,:reverse_each,:rindex,:select,:shift,:size,
       :slice,:slice!,:sort,:sort!,:to_a,:to_ary,:transpose,:uniq,:uniq!,:unshift,:values_at,:zip,
       :|,:all?,:any?,:collect,:detect,:each_cons,:each_slice,:each_with_index,:entries,:enum_cons,
       :enum_slice,:enum_with_index,:find_all,:grep,:include?,:inject,:map,:max,:member?,:min,
       :partition,:reject,:select,:sort,:sort_by,:to_a,:to_set

   # Make sure the measuremed path is reasonable
   def sanitize_hops!()
       # TODO: don't return... raise!
       if @hops.find { |h| !h.respond_to?(:ip) or !h.ip or !h.respond_to?(:ttl) or !h.ttl } or @hops.empty?
            @hops = []
            return
       end
       get_rid_of_wonky_last_hop
       remove_redundant_dsts
       get_rid_of_trailing_zeros
   end

   # Often for BGP Mux nodes, the last hop (TTL=40) will be total garbage. TODO: this santiziation should
   # perhaps be performed at the measurement issuer
   def get_rid_of_wonky_last_hop()
       # Get rid of wonky 40th hop with random IPs
       return if @hops[-1].ip == @dst

       # first case: large disparity between second to last and last ttl
       if @hops.size >= 2 and (@hops[-1].ttl.to_i - @hops[-2].ttl.to_i) > @@last_hop_sanity_check_distance 
            @hops = @hops[0..-2]
       end

       # second case: ttls actually make sense, but there is still a long
       # string of 0.0.0.0s
       if @hops.size >= @@last_hop_sanity_check_distance + 1 and @hops[-1].ip != "0.0.0.0" and
                @hops[-(@@last_hop_sanity_check_distance+1), @@last_hop_sanity_check_distance]\
                     .map { |h| h.ip } == ["0.0.0.0"] * @@last_hop_sanity_check_distance 
            @hops = @hops[0..-2]
       end

       # third case: only hop is the forty-eth
       #   (ASSUMES no intermediate 0.0.0.0s...)
       if @hops[0].ttl.to_i == 40
           @hops = @hops[0..-2]
       end
   end

   # Sometimes the destination appears many times in a sequence at the end of
   # the path
   def remove_redundant_dsts()
        while @hops.size > 1 and @hops[-1].ip == @dst and @hops[-2].ip == @dst
            @hops = @hops[0..-2]
        end
   end

   # A long line of 0.0.0.0s at the end is not helpful
   def get_rid_of_trailing_zeros()
        while !@hops.empty? and @hops[-1].ip == "0.0.0.0"
            @hops = @hops[0..-2] 
        end
   end
      
   # Sort hops, and fill in gaps with "0.0.0.0"s
   def canonocalize_hops!()
       # Sort
       @hops = @hops.sort_by { |hop| hop.ttl }

       # Fill in gaps
       return if @hops.empty?
       return if @hops[-1].ttl > 45 # packet corruption perhaps...
       @hops.each_with_index do |hop, i|
           return if i+1 == @hops.size
           # look ahead to the next hop
           next_hop = @hops[i+1]
           if next_hop.ttl != hop.ttl + 1
                filler_hop = Hop.new
                filler_hop.ip = "0.0.0.0"
                filler_hop.ttl = hop.ttl + 1
                # on next iteration, this will be the current hop
                @hops.insert(i+1, filler_hop)
           end
       end
   end

   # We used to have a valid? flag, which made .find() calls crash. TODO: 
   # maintain failure reasons separately from @hops so that this isn't
   # necessary
   def find(&block)
       return nil unless valid?
       @hops.find(&block)
   end

   # Does the path traverse the given ASN?
   def passes_through_as?(asn)
      !@hops.find { |hop| hop.asn == asn }.nil?
   end

   # Return an ordered list of ASNs this path passes through
   def compressed_as_path()
       # .uniq assumes no AS loops
       # TODO: do I need the find_all?
       as_path().find_all { |asn| !asn.nil? }.uniq 
   end

   # Return an ordered list of ASN mappings for each hop this path passes through
   def as_path()
       @hops.map { |hop| hop.asn }
   end

   # Return an ordered list of prefixes for each hop this path passes through
   # we take an ip_info for the logged hops without prefixes
   def prefix_path(ip_info=nil)
       #                get rid of MockHops or invalid Hops
       @hops.find_all { |hop| hop.is_a?(Hop) }.map { |hop| (ip_info) ? ip_info.getPrefix(hop.ip) : hop.prefix }
   end

   # Return an ordered list of prefixes this pass traverses
   def compressed_prefix_path
       prefix_path().find_all { |prefix| !prefix.nil? }.uniq
   end

   # Return a path with no intermediate 0.0.0.0s
   def without_zeros()
       @hops.find_all { |hop| hop.ip != "0.0.0.0" }
   end

   # Return the # of hops along this path which do not show up in RIPE feeds
   def num_not_advertised
       @hops.find_all { |hop| hop.prefix.nil? }.size
   end

   # Return the number of hops which are not ping responsive
   def num_non_responsive
       @hops.find_all { |hop| !hop.ping_responsive }.size
   end

   # Are the contents of this path sane?
   # overriden by subclasses if necessary
   def valid?()
       (@invalid_reason.nil? && !(@hops.find { |h| h.is_a?(Symbol) or h.is_a?(String) }))
   end

   # Does this path contain a loop?
   def contains_loop?()
       no_zeros = @hops.map { |hop| hop.ip }.find_all { |ip| ip != "0.0.0.0" }
       adjacents_removed = Path.new(@src, @dst)

       (0..(no_zeros.size-2)).each do |i|
          adjacents_removed << no_zeros[i] if no_zeros[i] != no_zeros[i+1]
       end
       adjacents_removed << no_zeros[-1] unless no_zeros.empty?

       return adjacents_removed.uniq.size != adjacents_removed.size
   end

   # Return the first router along this path inside of the given ASN
   def ingress_router_to_as(as)
      for hop in self
        # is hop.asn is assigned?
        return hop if hop.asn == as 
      end
      return nil
   end

   def to_s
       @hops.map { |h| h.to_s }.inspect
   end

   # Turn @hops into a doubly linked list to allow for traversal given only a
   # reference to a Hop. 
   def link_listify!
       return if !valid?
       (0...@hops.size).each do |i| 
          @hops[i].previous = (i == 0) ? nil : @hops[i-1]
          @hops[i].next = @hops[i+1]
       end
   end

   # Do the two paths share a a common subsequence at the beginning?
   def self.share_common_path_prefix?(path1, path2)
      # trs and spooftrs sometimes differ in length. We look at the common
      [path1.size, path2.size].min.times do |i|
         # occasionally spooftr will get *'s where tr doesn't, or vice
         # versa. Look to make sure the next hop isn't the same
         if path1[i] != path2[i] and 
             path1[i] != path2[i+1] and path1[i+1] != path2[i]
             return false
         end
      end

      return true
   end

   # returns the first hop in path1 that diverges from path2
   def self.first_point_of_divergence(path1, path2)
      path1.size.times do |i| 
          return path1[i] if path1[i] != path2[i]
      end
      return nil
   end
end

# rawr, namespace collision with reverse_traceroute.rb
class RevPath < Path
   def initialize(src, dst, init_hops=[])
        super(src, dst, init_hops)
   end

   #def last_responsive_hop()
   #    self.find { |hop| !hop.is_a?(MockHop) && hop.ping_responsive && hop.ip != "0.0.0.0" }
   #end

   def as_path()
       return [] unless valid?
       super
   end

   # Are all hops ping responsive (or not historically pingable) except the
   # destionation?
   def ping_responsive_except_dst?(dst)
       return false if @hops.empty?

       # first hop of the reverse traceroute is the destination
       for hop in @hops[1..-1]
          return false if !hop.ping_responsive && hop.historically_pingable?
       end

       return true
   end

   # Return the number of hops that were inferred from symmetry assumptions
   def num_sym_assumptions()
      count = 0
      for hop in @hops
          count += 1 if hop.type == :sym or hop.type == "sym"
      end
      count
   end

   # Return the longest consecutive sequence of symmetry assumptions
   def longest_sym_sequence()
      count = 0
      max = 0
      for hop in @hops
         if hop.type != :sym and hop.type != "sym"
           count = 0 
         else
           count += 1
           max = (count > max) ? count : max
         end
      end

      max
   end

   def unresponsive_hop_farthest_from_dst()
       last_hop = @hops[1]
       for hop in @hops
          if hop.ping_responsive
            return last_hop
          end

          last_hop = hop
       end

       return (last_hop.no_longer_pingable?) ? last_hop : nil
   end

   # return all hops within the dst as, or the first egress router outside of
   # the dst as
   def all_hops_adjacent_to_dst_as
        adjacent_hops = []
        return adjacent_hops unless valid?

        dst_as = @hops[0].asn

        return adjacent_hops if dst_as.nil?

        @hops.each do |hop| 
            adjacent_hops << hop
            break if hop.asn != dst_as         
        end

        adjacent_hops
   end

   # Return first non-zero hop
   def first_hop()
        @hops.find { |hop| !hop.ip.nil? && hop.ip != "0.0.0.0" }
   end

   # did we back off of the destination?
   def measured_from_destination?(dst)
        first_hop().ip == dst
   end
end

class HistoricalReversePath < RevPath
   attr_accessor :timestamp, :src, :dst, :valid

   def initialize(src, dst, init_hops=[])
       super(src, dst, init_hops)
       @timestamp = 0 # measurement timestamp
       @valid = false # if false, then there was nothing found in the DB
       @invalid_reason = "unknown" # if valid==false, this will explain the current probe status
       @src = "" # should be clear
       @dst = "" # ditto
   end

   # We used to put failure reasons into the @hops themselves. TODO: store
   # failre reasons separately
   def valid?
       return (@valid || !@hops.find { |hop| hop.valid_ip }.nil?) && !@hops.empty?
   end
   
   def to_s
       # print the pretty output
       result = "From #{@src} to #{@dst} at #{@timestamp}:\n"
       result << @hops.map { |x| x.to_s }.join("\n") if @valid
       result << "Failed query, reason: #{@invalid_reason}" if !@valid
       result
   end
end

# some of the classes in the logs are from the old ReversePathSimple. This is
# purely for backwards compatibility
class ReversePathSimple < Array
end

class SpoofedReversePath < RevPath
    # not too many sym assumptions?
    def successful?()
        return false if @hops.size < 2

        # :dst_sym is ignored, I think

        # We actually only require that there is no sequence of more than two symmetric assumptions.
        # Also, symmetry can't be assumed next to the destination
        return !more_than_n_consecutive_sym_assumptions?(2) &&
            @hops[-2].type != :sym
    end

    def more_than_n_consecutive_sym_assumptions?(n)
       sym_count = 0

       for hop in @hops
          if hop.type == :sym
              sym_count += 1
              return true if sym_count > n
          else
              sym_count = 0
          end
       end

       return false
    end
end

# Encapsulates: normal traceroute, spoofed traceroute, and historical traceroute
class ForwardPath < Path
   # Is the last hop within the destination's AS?
   def reached_dst_AS?(dst, ipInfo)
       dst = dst.is_a?(Hop) ? dst.ip.strip : dst.strip
       return false if dst.nil?
       dst_as = ipInfo.getASN(dst)
       last_non_zero_hop = last_non_zero_ip
       last_hop_as = (last_non_zero_hop.nil?) ? nil : ipInfo.getASN(last_non_zero_hop)
       return !dst_as.nil? && !last_hop_as.nil? && dst_as == last_hop_as
   end

   def last_non_zero_ip
        hop = last_non_zero_hop
        return (hop.nil?) ? nil : hop.ip
   end

   def last_non_zero_hop()
        last_hop = @hops.reverse.find { |hop| hop.ip != "0.0.0.0" }
        return (last_hop.nil? || last_hop.is_a?(MockHop)) ? nil : last_hop
   end

   # Did the measurement reach the given destination?
   def reached?(dst)
        dst = dst.is_a?(Hop) ? dst.ip : dst
        dst = dst.strip
        #$LOG.puts" reached?: #{@hops.inspect}"
        !@hops.find { |hop| hop.ip.strip == dst }.nil?
   end

   # Are all hops ping responsive (or not historically pingable) except the
   # destination?
   def ping_responsive_except_dst?(dst=nil)
       return false if @hops.empty?

       for hop in @hops[0..-2]
          return false if !hop.ping_responsive && hop.historically_pingable?
       end

       # also filter out if there are a bunch of 0.0.0.0s before the
       # destination

       return false if @hops.size > 3 and @hops[-2].ip == "0.0.0.0" and @hops[-3].ip == "0.0.0.0"

       return true
   end

   def last_responsive_hop()
       # for normal tr this is exactly what we want
       # for historical tr and spoofed tr, we actually want to identify
       # the first /non-responsive/ hop as the suspected failure
       @hops.reverse.find { |hop| !hop.is_a?(MockHop) && hop.ping_responsive && hop.ip != "0.0.0.0" }
   end

   def valid?()
      return !@invalid_reason && @hops.size > 1
   end
end

# Used for verifiying that alternate paths are viable. See
# FailureAnalyzer.splice_paths
class SplicedPath
    attr_accessor :src, :dst, :ingress, :trace, :revtr
    def initialize(src, dst, ingress, trace, revtr)
        @src = src
        @dst = dst
        @ingress = ingress
        @trace = trace
        @revtr = revtr
    end
end

# =============================================================================
#                            Hops                                            #
# =============================================================================

# Generic class for a single hop along a path
class Hop
    attr_accessor :ip, :prefix, :dns, :ttl, :asn, :ping_responsive, :last_responsive, :formatted, :reachable_from_other_vps, :next, :previous

    include Comparable

    def initialize(*args)
        @ping_responsive = false
        case args.size
        when 0 # nothing!
        when 1 # just the ip
            @ip = args.shift
        when 2 # ip, ip_info
            @ip, ipInfo = args
            @dns = ipInfo.resolve_dns(@ip,@ip)
            @prefix, @asn = ipInfo.getInfo(@ip)
            @formatted = ipInfo.format(@ip, @dns, @asn)
        when 3 # ip, dns, ip_info
            @ip, @dns, ipInfo = args
            @prefix, @asn = ipInfo.getInfo(@ip)
            @formatted = ipInfo.format(@ip, @dns, @asn)
        end
    end

    # Does @ip look like an IP address?
    def valid_ip
        @ip.matches_ip?
    end

    # Alias resolution! Lazily evaluated
    def cluster()
        @cluster ||= $ip2cluster[@ip]
        @cluster
    end

    # Which of the two hops is closer to the dest?
    def self.later(tr_suspect, spooftr_suspect)
        if tr_suspect.nil?
            return spooftr_suspect
        elsif spooftr_suspect.nil?
            return tr_suspect
        else
            return (tr_suspect.ttl > spooftr_suspect.ttl) ? tr_suspect : spooftr_suspect
        end
    end

    def historically_pingable?
        return @last_responsive != "N/A" && @last_responsive
    end

    # TODO: better name
    def pingable_from_other_vps
        return !@ping_responsive && @reachable_from_other_vps
    end

    # Is this hop a (veritable) border router?
    def on_as_boundary?
        if !@previous.nil? && @previous.asn != @asn && @previous.ip != "0.0.0.0"
            return @previous.asn
        end

        if !@next.nil? && @next.asn != @asn && @next.ip != "0.0.0.0"
            return @next.asn
        end

        return false
    end

    # Did this hop appear directly adjacent to the given IP?
    # TODO: use alias clustering, which is even better!
    def adjacent?(ip)
       return true if @ip == ip
       return true if !@next.nil? and @next.ip == ip
       return true if !@previous.nil? and @previous.ip == ip
       return false
    end

    def to_s
        (@formatted or @ip)
    end

    def inspect
        "Hop: #{@ip} #{@prefix} #{@dns} #{@asn}"
    end

    # takes a block, and returns any subsequent hop for which the block
    # evaluates to true
    def find_subsequent()
        curr = self
        while !curr.next.nil?
            curr = curr.next 
            return curr if yield curr
        end

        return nil
    end

    def no_longer_pingable?
        return !@ping_responsive && @last_responsive
    end
end

# Used to be used for DOT graph generation, but no longer necessary
# TODO: just instantiate a Hop object...
MockHop = Struct.new(:ip, :dns, :ttl, :asn, :ping_responsive, :last_responsive, :reverse_path, :reachable_from_other_vps)

# We added these fields after mkdot was written?
class MockHop
    attr_accessor :next, :previous
end

class ForwardHop < Hop 
    attr_accessor :reverse_path
    def initialize(ttlhop, ipInfo)
        @ttl = ttlhop[0]
        @ip = ttlhop[1]
        @dns = ipInfo.resolve_dns(@ip, @ip) 
        @prefix, @asn = ipInfo.getInfo(@ip)
        @formatted = ipInfo.format(@ip, @dns, @asn)
        @reverse_path = []
        @ping_responsive = (@ip != "0.0.0.0")
        @last_responsive = (@ip != "0.0.0.0")
    end

    def to_s()
        "#{@ttl}.  #{(@formatted.nil?) ? "" : @formatted.clone}"
    end

    def inspect
        "Fwd hop: #{@ip} #{@prefix} #{@dns} #{@asn}"
    end
end

class HistoricalForwardHop < Hop
    attr_accessor :reverse_path
    def initialize(ttl, ip, ipInfo)
        @ttl = ttl
        @ip = ip
        @dns = ipInfo.resolve_dns(@ip, @ip) 
        @prefix, @asn = ipInfo.getInfo(@ip)
        @formatted = ipInfo.format(@ip, @dns, @asn)
        @reverse_path = []
    end

    def to_s()
       s = "#{@ttl}.  #{@formatted} (pingable from S?: #{@ping_responsive}) [historically pingable?: #{@last_responsive.inspect}]"
    end

    def inspect
        "Historical fwd hop: #{@ip} #{@prefix} #{@dns} #{@asn}"
    end
end

class ReverseHop < Hop
    attr_accessor :valid_ip, :type
    def initialize(*args)
        case args.size
        when 2 # parse from formatted string
            formatted, ipInfo = args
            $stderr.puts "formatted was nil!" if formatted.nil?
            @formatted = formatted
            # could be a true hop, or could be "No matches in the past 1440 minutes!"
            # XXX: I don't like how fragile this regex is.... if Dave changes the
            # output format...   Use the actual ReverseTraceroute object rather
            # than parsing the output string
            match = formatted.scan(/^[ ]*(\d+)(.*)\((.*)\).*(rr|ts|sym|tr2src|dst|tr)/)

            if match.empty?
                @ttl = -1
                @dns = ""
                @ip = "0.0.0.0"
                @valid_ip = false
                @type = nil
            else
                @ttl = match[0][0]
                @dns = match[0][1].strip
                @ip = match[0][2]
                @valid_ip = true
                @type = match[0][3]
                @type = @type.to_sym unless @type.nil?
            end

            # deal with the weird case where the IP is not included in the output
            if @ip !~ /\d+\.\d+\.\d+\.\d+/
                @dns = @ip
                @ip = Resolv.getaddress(@ip) 
                @ttl = -1
            end

            # deal with the weird case where the DNS is not included in the output
            if @valid_ip and @dns.empty?
                @dns = @ip
            end

        when 5 # parse from print_cached_reverse_path_reasons.rb
            @ip, @ttl, @type, sym_reasons, ipInfo = args
            @type = @type.to_sym
            @dns = ipInfo.resolve_dns(@ip, @ip)
            @ttl = @ttl.to_i
            @valid_ip = (@ip != "0.0.0.0")
            @formatted = "#{@ttl}.  #{dns} (#{@ip}) #{@type}"
            @formatted << " {#{sym_reasons}}" if sym_reasons
        else
            raise "unknown number of initializer args for ReverseHop"
        end

        begin
            @prefix, @asn = ipInfo.getInfo(@ip)
        rescue Exception => e
            # XXX for debugging purposes
            Emailer.isolation_exception("formatted: #{@formatted} \n#{e} \n#{e.backtrace.join("<br />")}").deliver
        end
    end

    def to_s()
        s = (@formatted.nil?) ? "#{@ip} #{@dns}" : @formatted.clone
    end

    def inspect
        "Reverse hop: #{@ip} #{@prefix} #{@dns} #{@asn}"
    end
end

class SpoofedForwardHop < Hop
    def initialize(hop_ip, ttl, ipInfo)
        raise "bad ttl #{ttl}" if ttl < 0
        @ip = hop_ip
        @ttl = ttl
        @dns = ipInfo.resolve_dns(@ip, @ip)
        @prefix, @asn = ipInfo.getInfo(@ip)
        @formatted = ipInfo.format(@ip, @dns, @asn)
    end

    def to_s()
        s = "#{@ttl}.  #{(@formatted.nil?) ? "" : @formatted.clone}"
        s << " (pingable from S?: #{@ping_responsive})" unless @ping_responsive.nil?
        s << " [historically pingable?: #{@last_responsive}]" unless @last_responsive.nil?
        s
    end

    def inspect
        "Spoofed fwd hop: #{@ip} #{@prefix} #{@dns} #{@asn}"
    end
end

if __FILE__ == $0
    require 'yaml'
    hop1 = Hop.new("1.2.3.4")
    hop1.ttl = 1
    hop2 = Hop.new("1.2.3.4")
    hop2.ttl = 2
    hop3 = Hop.new("1.2.3.4")
    hop3.ttl = 3
    hop40 = Hop.new("22.22.22.22")
    hop40.ttl = 40

    test = [hop1, hop2, hop3, hop40]

    src = "1.2.2.2"
    dst = "1.2.3.4"
    r = HistoricalReversePath.new(src, dst, test)
    t = ForwardPath.new(src, dst, test)
    q = SpoofedReversePath.new(src, dst, test)
    u = Path.new(src, dst, test)

    puts r.inspect
    puts q.inspect
    puts u.inspect
    puts t.inspect
end
