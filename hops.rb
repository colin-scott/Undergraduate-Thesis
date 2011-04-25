#!/homes/network/revtr/ruby/bin/ruby

# last_responsive will be 
#    * "N/A" if not in the database
#    * false if not historically pingable
#    * A Time object if historically pingable
#    * nil if not initialized (not grabbed from the DB yet)


# =============================================================================
#                            Paths                                            #
# =============================================================================

require 'forwardable'

class Path
   attr_accessor :hops

   def initialize(init_hops=[])
      @hops = Array.new(init_hops)
   end

   # delegate methods to @hops!!!
   extend Forwardable
   def_delegators :@hops,:&,:*,:+,:-,:<<,:<=>,:[],:[],:[]=,:abbrev,:assoc,:at,:clear,:collect,:collect!,:compact,:compact!,:concat,:delete,:delete_at,:delete_if,:each,:each_index,:empty?,:fetch,:fill,:first,:flatten,:flatten!,:hash,:include?,:index,:indexes,:indices,:initialize_copy,:insert,:join,:last,:length,:map,:map!,:nitems,:pack,:pop,:push,:rassoc,:reject,:reject!,:replace,:reverse,:reverse!,:reverse_each,:rindex,:select,:shift,:size,:slice,:slice!,:sort,:sort!,:to_a,:to_ary,:transpose,:uniq,:uniq!,:unshift,:values_at,:zip,:|,:all?,:any?,:collect,:detect,:each_cons,:each_slice,:each_with_index,:entries,:enum_cons,:enum_slice,:enum_with_index,:find,:find_all,:grep,:include?,:inject,:map,:max,:member?,:min,:partition,:reject,:select,:sort,:sort_by,:to_a,:to_set

   # SpoofedReversePath.valid? kind of throws a wrench into this whole
   # endeavor...  override!
   def compressed_as_path()
       # .uniq assumes no AS loops
       # TODO: do I need the find_all?
       as_path().find_all { |asn| !asn.nil? }.uniq 
   end

   def as_path()
       @hops.map { |hop| hop.asn }
   end

   # overriden if necessary
   def valid?()
       return true
   end

   def contains_loop?()
       no_zeros = @hops.map { |hop| hop.ip }.find_all { |ip| ip != "0.0.0.0" }
       return no_zeros.uniq.size != no_zeros.size
   end

   def to_s
     @hops.inspect
   end
end

# fuckin' namespace collision with reverse_traceroute.rb
class RevPath < Path
   #def last_responsive_hop()
   #    self.find { |hop| !hop.is_a?(MockHop) && hop.ping_responsive && hop.ip != "0.0.0.0" }
   #end

   def as_path()
       return [] unless valid?
       super
   end

   def ping_responsive_except_dst?(dst)
       return false if @hops.empty?

       # first hop of the reverse traceroute is the destination
       for hop in @hops[1..-1]
          return false if !hop.ping_responsive && hop.historically_pingable?
       end

       return true
   end

   def num_sym_assumptions()
      count = 0
      for hop in @hops
          count += 1 if hop.type == :sym or hop.type == "sym"
      end
      count
   end

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
  def unresponsive_hop_closest_to_dst()
        return @hops.find { |hop| !hop.ping_responsive }
    end
end

class HistoricalReversePath < RevPath
   attr_accessor :timestamp, :invalid_reason, :src, :dst, :valid

   def initialize(init_hops=[])
       super(init_hops)
       @timestamp = 0 # measurement timestamp
       @valid = false # if false, then there was nothing found in the DB
       @invalid_reason = "unknown" # if valid==false, this will explain the current probe status
       @src = "" # should be clear
       @dst = "" # ditto
   end

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

# some of the classes in the logs are from the old ReversePathSimple
class ReversePathSimple < Array
end

class SpoofedReversePath < RevPath
    def valid?()
        return @hops.size > 1 && !(@hops[0].is_a?(Symbol) || @hops[0].is_a?(String))
    end

    # not that many sym assumptions?
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

# normal traceroute, spoofed traceroute, historical traceroute
class ForwardPath < Path
   def reached_dst_AS?(dst, ipInfo)
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

   def reached?(dst)
        #$LOG.puts" reached?: #{@hops.inspect}"
        !@hops.find { |hop| hop.ip == dst }.nil?
   end

   def ping_responsive_except_dst?(dst)
       return false if @hops.empty?

       for hop in @hops[0..-2]
          return false if !hop.ping_responsive && hop.historically_pingable?
       end

       return true
   end

   def last_responsive_hop()
       # for normal tr this is exactly what we want
       # for historical tr and spoofed tr, we actually want to identify
       # the first /non-responsive/ hop as the suspected failure
       @hops.reverse.find { |hop| !hop.is_a?(MockHop) && hop.ping_responsive && hop.ip != "0.0.0.0" }
   end
end

# =============================================================================
#                            Hops                                            #
# =============================================================================

class Hop
    attr_accessor :ip, :dns, :ttl, :asn, :ping_responsive, :last_responsive, :formatted, :reachable_from_other_vps
    def initialize(*args)
        @ping_responsive = false
        case args.size
        when 1 # just the ip
            @ip = args.shift
        end
    end

    def <=>(other)
        @ttl <=> other.ttl
    end

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
end

# wait a minute... we could just instantiate a Hop object...
MockHop = Struct.new(:ip, :dns, :ttl, :asn, :ping_responsive, :last_responsive,
                     :reverse_path)


class HistoricalForwardHop < Hop
    attr_accessor :reverse_path
    def initialize(ttl, ip, ipInfo)
        @ttl = ttl
        @ip = ip
        @dns = ipInfo.resolve_dns(@ip, @ip) 
        @asn = ipInfo.getASN(@ip)
        @formatted = ipInfo.format(@ip, @dns, @asn)
        @reverse_path = []
    end

    def to_s()
       s = "#{@ttl}.  #{@formatted} (pingable from S?: #{@ping_responsive}) [historically pingable?: #{@last_responsive.inspect}]"
       s << "\n  <ul type=none>\n"
       reverse_path.each do |hop|
           s << "    <li> #{hop}</li>\n"
       end
       s << "  </ul>\n"
       s
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
            @asn = ipInfo.getASN(@ip)
        rescue Exception => e
            # XXX for debugging purposes
            Emailer.deliver_isolation_exception("formatted: #{formatted} \n#{e} \n#{e.backtrace.join("<br />")}") 
        end
    end

    def to_s()
        s = (@formatted.nil?) ? "" : @formatted.clone
        s << " [ASN: #{@asn}]" if @valid_ip
        s << " (pingable from S?: #{@ping_responsive})" if @valid_ip and !@ping_responsive.nil?
        s << " [historically pingable?: #{@last_responsive or "false"}]" if @valid_ip
        s
    end
end

class ForwardHop < Hop
    attr_accessor :reverse_path
    def initialize(ttlhop, ipInfo)
        @ttl = ttlhop[0]
        @ip = ttlhop[1]
        @dns = ipInfo.resolve_dns(@ip, @ip) 
        @asn = ipInfo.getASN(@ip)
        @formatted = ipInfo.format(@ip, @dns, @asn)
        @reverse_path = []
        @ping_responsive = (@ip != "0.0.0.0")
        @last_responsive = (@ip != "0.0.0.0")
    end

    def to_s()
        "#{@ttl}.  #{(@formatted.nil?) ? "" : @formatted.clone}"
    end
end

class SpoofedForwardHop < Hop
    def initialize(ttlhops, ipInfo)
        @ttl = ttlhops[0]
        @ip = ttlhops[1][0]  # XXX for now, just take the first ip...
        @dns = ipInfo.resolve_dns(@ip, @ip)
        @asn = ipInfo.getASN(@ip)
        @formatted = ipInfo.format(@ip, @dns, @asn)
    end

    def to_s()
        s = "#{@ttl}.  #{(@formatted.nil?) ? "" : @formatted.clone}"
        s << " (pingable from S?: #{@ping_responsive})" unless @ping_responsive.nil?
        s << " [historically pingable?: #{@last_responsive}]" unless @last_responsive.nil?
        s
    end
end

if __FILE__ == $0
    require 'yaml'
    test = [1,32,4]
    r = HistoricalReversePath.new(test)
    t = ForwardPath.new(test)
    q = SpoofedReversePath.new(test)
    u = Path.new(test)

    puts r.inspect
    puts q.inspect
    puts u.inspect
    puts t.inspect
end
