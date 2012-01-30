#!/homes/network/revtr/ruby-upgrade/bin/ruby

# Utilities methods, along with custom defined Monkey Wrenching to built-in
# classes

require 'isolation_module'
require 'syslog'
require 'date'
require 'logger'
require 'thread'
require 'forwardable'
require 'set'

if RUBY_PLATFORM != 'java'
  require 'inline'
end

# We don't want to be forced to load adjacencies et. al., so in case the
# caller hasn't already loaded spooftr_config, we re-define here.
# ||= so we don't redefine it
# TODO: make the revtr adjacencies lazily evaluated, so that this hack isn't
# needed
$LOG ||= $stderr
$BASEDIR ||= "/homes/network/revtr/spoofed_traceroute"
$DATADIR ||= "#{$BASEDIR}/data"
$CONTROLLER_INFO ||= "#{$DATADIR}/uris/controller.txt"
$TRACEROUTE_SERVER_INFO ||= "#{$DATADIR}/uris/tracerouteserver.txt"
$ADJACENCY_SERVER_INFO ||= "#{$DATADIR}/uris/adjacencyserver.txt"
$VP_SERVER_INFO ||= "#{$DATADIR}/uris/vpserver.txt"
$TR_ATLAS_INFO ||= "/homes/network/revtr/revtr/revtr_data/uris/atlas_uri"
$TR_ATLAS_STATE ||= "/homes/network/revtr/revtr/revtr_data/atlas_state"

class Method
    # Make the Method.to_s human readable
    def to_hs
        str = self.to_s

        # "#<Method: String#count>"
        return str.gsub(/#<Method: /, '').gsub(/>$/, '').split("#")[1]
    end
end

class Object
   # Ruby doesn't support deep copy out-of-the-box.
   def deep_copy( object )
     Marshal.load( Marshal.dump( object ) )
   end
end

class Hash
    # Keep the keys the same, but apply a map function to all the values
    def map_values()
        new_hash = {} 
        self.each do |k,v|
            new_hash[k] = yield v
        end
        new_hash
    end

    # Slightly different than .values(): assumes all values are lists, and
    # reduces the lists into a single set
    def value_set()
        values = self.values
        values.each { |elt| raise "not a list! #{elt}" if !elt.is_a?(Array) and !elt.is_a?(Set) }
        return self.values.reduce(Set.new) { |sum,nex| sum | nex }
    end

    # Return a hash from value -> [key1, key2, ...] that map to that value
    def value2keys
        h = Hash.new { |h,k| h[k] = [] }
        self.each do |k,v|
           h[v] << k
        end
        h 
    end
end

class Set
    # So that Sets play well with Arrays
    alias :to_ary :to_a    

    # Return a string, exactly like Array#join
    def join(sep=$,)
        self.to_a.join(sep)
    end

    # Iterate over values, exactly like Array#each
    def each()
       self.to_a.each { |elt| yield elt }
    end
end

class Array
    # Turn an Array of pairs (e.g. [[1,2], [3,4]]
    # into a Hash ({1=>2,3=>4}).
    #
    # NOTE: can't name this to_hash(), since that is defined in ActiveRecord
    # libraries
    def custom_to_hash()
        hash = {}
        self.each do |elt|
            raise "not a pair! #{elt.inspect}" if elt.size != 2
            hash[elt[0]] = elt[1]
        end

        hash
    end

    # given a hash from elt -> category, iterates over all elements of array and returns a new
    # hash from category -> [list of elts in the category]
    #
    # takes an optional second argument -> the category to assign to unknown
    # elts
    # else, ignores elts that don't have a category
    #
    # Example Usage:
    # ips.categorize(FailureIsolation.IPToPoPMapping, DataSets::Unknown)
    def categorize(elt2category, unknown=nil)
        categories = Hash.new { |h,k| h[k] = [] }
        self.each do |elt|
           if elt2category.include? elt
                categories[elt2category[elt]] << elt 
           elsif unknown
                categories[unknown] << elt
           end
        end
        categories
    end

    # Given the name of a method or object field, categorize this Array as in
    # Array#categorize(), where all elements with the same method or field
    # value are put into the same category.
    #
    # Example usage:
    # outages.categorize_on_attr("dst")
    # # -> returns a hash from outage destination -> [list of outages with
    # that destination]
    def categorize_on_attr(send_name)
        categories = Hash.new { |h,k| h[k] = [] }
        self.each do |elt|
            if !elt.respond_to?(send_name)
                raise "elt #{elt} doesn't respond to #{send_name}"
            else
                categories[elt.send(send_name)] << elt
            end
        end
        categories
    end
 
    # Run binary search on the (sorted) Array
    # field is the method to issue a send to
    def binary_search(elem, field=nil, low=0, high=self.length-1)
      mid = low+((high-low)/2).to_i
      if low > high 
        return -(low + 1)
      end
      mid_elt = (field.nil?) ? self[mid] : self[mid].send(field)
      if elem < mid_elt
        return binary_search(elem, field, low, mid-1)
      elsif elem > mid_elt
        return binary_search(elem, field, mid+1, high)
      else
        return mid
      end
    end

    # Return whether the Array is sorted according to <=>
    def sorted?(field=nil)
        return true if self.empty?

        if field.nil?
            last = self[0]
        else
            last = self[0].send(field)
        end

        self[1..-1].each do |elt|
            curr = (field.nil?) ? elt : elt.send(field)
            return false if curr < last
            last = curr
        end

        return true
    end

    # Return the most commonly occuring element of the Array
    def mode()
        counts = Hash.new(0)
        self.each { |elt| counts[elt] += 1 }
        return nil if counts.empty?
        max_val = counts[self[0]]
        max_key = self[0]

        counts.each do |elt,count|
            if count > max_val
                max_val = count
                max_key = elt
            end
        end
        max_key
    end

    # Shuffle the elements of the Array in random order
    def shuffle!()
        shuffled = self.sort_by { rand }

        # TODO: better way to modify self?
        shuffled.each_with_index do |i, elt|
            print i
            self[i] = elt
        end
    end
end

class String
    # Return whether the string looks like an IP address (e.g. 12.2.5.185)
    #
    # NOTE: Doesn't sanity check values (e.g., greater than 255)
    def matches_ip?()
        return self =~ /\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/
    end
end

module ProbeController

#   $server_info = {
#     $CONTROLLER_INFO => {:name => "Controller"},
#     $ADJACENCY_SERVER_INFO => {:name => "Adjaceny Server"},
#     $TR_ATLAS_INFO => {:name => "Traceroute Atlas"},
#     $TRACEROUTE_SERVER_INFO => {:name => "Traceroute Server"},
#     $VP_SERVER_INFO => {:name => "VP Server"},
#     $VP_LOGGER_INFO => {:name => "VP LOGGER"}
#   }

  $server_info = {
    :controller => {:uripath => $CONTROLLER_INFO},
    :adjacency_server => {:uripath => $ADJACENCY_SERVER_INFO},
    :tr_atlas => {:uripath => $TR_ATLAS_INFO},
#   :tr_server => {:uripath => $TRACEROUTE_SERVER_INFO},
    :vp_server => {:uripath => $VP_SERVER_INFO},
    :vp_logger => {:uripath => $VP_LOGGER_INFO}
  }

  # this lets us override the defualt, which is to use a DRb object
  # now, the local process (say, the controller process) can set the
  # controller server to be the object, rather than a DRb stub to the
  # object, so calls can be made directly on it
  # if this is set, won't use DRb
  # can be reset to DRb by setting to nil
  def ProbeController::set_server(server_info,server)
    $server_info[server_info][:server] = server
    $LOG.puts "Setting to #{server_info.to_s} #{server}"
  end

  # this lets us override the server uri, which would normalling come from
  # readin in off disk
  # note: if the :uri has been set (say, by a test controller), but then an
  # exception is thrown, this will reset it to looking up the uri off disk
  # so will stop using the test one
  def ProbeController::set_server_uri(server_info,uri)
    $server_info[server_info][:uri]=uri
    $LOG.puts "Setting URI to #{server_info.to_s} #{uri}"
  end

  def ProbeController::get_server_uri(server_info)
    $server_info[server_info][:uri]
  end

  # note: if the :uri has been set (say, by a test controller), but then an
  # exception is thrown, this will reset it to looking up the uri off disk
  # so will stop using the test one
  def ProbeController::issue_to_server(server_info, retries=1, &method)
    failed_connections=0
    begin
      if $server_info[server_info][:server].nil?
        if $server_info[server_info][:uri].nil?
          $server_info[server_info][:uri]=`cat #{$server_info[server_info][:uripath]} 2>/dev/null`  
        end
        $LOG.puts "Connecting to #{server_info.to_s} #{$server_info[server_info][:uri]}"
        $server_info[server_info][:server] = DRbObject.new nil, $server_info[server_info][:uri]
      end
      if($TIMING) then
        timer = Time.now
      end
      results=method.call($server_info[server_info][:server])
      if($TIMING) then
        $LOG.puts "TIMING: call to #{server_info.to_s} took #{Time.now - timer} seconds"
        #$LOG.puts "Call was: #{method.to_ruby}"
      end
      return results
    rescue DRb::DRbConnError,DRb::DRbBadURI,TypeError
      $server_info[server_info][:server]=nil
      $server_info[server_info][:uri]=nil
      failed_connections += 1
      if(retries == -1) then #if retries is -1, then puts the error but don't raise an exception. 
        $LOG.puts(["#{server_info.to_s} refused connection, retrying","EXCEPTION!  #{server_info.to_s} refused connection, retrying: " + $!.to_s], $DRB_CONNECT_ERROR)
      elsif failed_connections<=retries
        $LOG.puts(["#{server_info.to_s} refused connection, retrying","EXCEPTION!  #{server_info.to_s} refused connection, retrying: " + $!.to_s+"\n"+$!.backtrace.join("\n")], $DRB_CONNECT_RETRY)
        sleep 10
        retry
      else
        $LOG.puts(["#{server_info.to_s} refused connection, failing", "EXCEPTION! #{server_info.to_s} refused connection, failing: " + $!.to_s + "\n" + $!.backtrace.join("\n")], $DRB_CONNECT_ERROR)
        raise DRb::DRbConnError, $!.message,$!.backtrace
      end
    end

  end

  def ProbeController::issue_to_controller(retries=1, &method)
    self.issue_to_server(:controller, retries, &method)
  end

  def ProbeController::issue_to_adjacency_server(retries=1, &method)
    self.issue_to_server(:adjacency_server, retries, &method)
  end

  def ProbeController::issue_to_vp_server(retries=1, &method)
    self.issue_to_server(:vp_server, retries, &method)
  end

  # deprecated
# def ProbeController::issue_to_tr_server(retries=1, &method)
#   self.issue_to_server(:tr_server, retries, &method)
# end

  def ProbeController::issue_to_tr_atlas(retries=1, &method)
    self.issue_to_server(:tr_atlas, retries, &method)
  end

  def ProbeController::issue_to_vp_logger(retries=-1, &method)
    self.issue_to_server(:vp_logger, retries, &method)
  end
end

module Inet
  def Inet::prefix(ip,length)
    ip=Inet::aton(ip) if  ip.is_a?(String) and ip.include?(".")
    return ((ip>>(32-length))<<(32-length))
  end

  if RUBY_PLATFORM != "java" 
    # Let's make Ruby's bit fiddling reasonably fast!
    inline(:C) do |builder|
         builder.include "<sys/types.h>"
         builder.include "<sys/socket.h>"
         builder.include "<netinet/in.h>"
         builder.include "<arpa/inet.h>"

         builder.prefix %{

         // 10.0.0.0/8
         #define lower10 167772160
         #define upper10 184549375
         // 172.16.0.0/12
         #define lower172 2886729728
         #define upper172 2887778303
         // 192.168.0.0/16
         #define lower192 3232235520
         #define upper192 3232301055
         // 224.0.0.0/4
         #define lowerMulti 3758096384
         #define upperMulti 4026531839
         // 127.0.0.0/16
         #define lowerLoop 2130706432
         #define upperLoop 2147483647
         // 169.254.0.0/16 (DHCP)
         #define lower169 2851995648
         #define upper169 2852061183
         // 0.0.0.0
         #define zero 0
         
         }

         builder.c_singleton %{

         // can't call ntoa() directly
         char *ntoa(unsigned int addr) {
             struct in_addr in;
             // convert to default jruby byte order
             addr = ntohl(addr);
             in.s_addr = addr;
             return inet_ntoa(in);
          }

          }

         builder.c_singleton %{

         // can't call aton() directly
         unsigned int aton(const char *addr) {
             struct in_addr in;
             inet_aton(addr, &in);
             // inet_aton() already gets the byte order correct I guess?
             return in.s_addr;
          }

          }

          builder.c_singleton %{
         
          int in_private_prefix(const char *addr) {
              // can't call aton() apparently?
              // so we'll just be redundant
              struct in_addr in;
              inet_aton(addr, &in);
              unsigned int ip = in.s_addr;

              if( (ip > lower10 && ip < upper10 ) || (ip > lower172 && ip < upper172)
                              || (ip > lower192 && ip < upper192) ||
                              (ip > lowerMulti && ip < upperMulti) ||
                              (ip > lowerLoop && ip < upperLoop) ||
                              (ip > lower169 && ip < lower169) ||
                              (ip == zero)) {
                  return 1;
              } else {
                  return 0;
              }
           }
         }
    end

    def self.in_private_prefix?(addr)
        self.in_private_prefix(addr) == 1;
    end
  else
    require 'java'
    # Too see these methods, run $ vim ~/jruby/lib/patricia-trie.jar
    # and look at org/adverk/collection/IpAddressConverter
    require '/homes/network/revtr/jruby/lib/patricia-trie.jar'
    IpAddressConverter = org.ardverk.collection.IpAddressConverter

	$PRIVATE_PREFIXES=[["192.168.0.0",16], ["10.0.0.0",8], ["127.0.0.0",8], ["172.16.0.0",12], ["169.254.0.0",16], ["224.0.0.0",4], ["0.0.0.0",8]]
   
	def Inet::ntoa( intaddr )
		IpAddressConverter.inet_ntoa(intaddr)
	end

	def Inet::aton(dotted)
		IpAddressConverter.inet_aton(dotted)
	end

    def Inet::in_private_prefix?(ip)
    	ip=Inet::aton(ip) if  ip.is_a?(String) and ip.include?(".")
    	$PRIVATE_PREFIXES.each do |prefix|
    		return true if Inet::aton(prefix.at(0))==Inet::prefix(ip,prefix.at(1))
    	end
    	return false
    end
  end
  
  $blacklisted_prefixes=nil
  def Inet::in_blacklisted_prefix?(ip)
    ip=Inet::aton(ip) if  ip.is_a?(String) and ip.include?(".")
    if $blacklisted_prefixes.nil?
      $blacklisted_prefixes = []
      File.open($BLACKLIST,"r").each do |line|
        prefix=line.chomp.split("/")
        $blacklisted_prefixes << [Inet::aton(prefix.at(0)),prefix.at(1).to_i]
      end
    end
    $blacklisted_prefixes.each{|prefix|
      return true if prefix.at(0)==Inet::prefix(ip,prefix.at(1))
    }
    return false
  end
end

# removes blacklisted and private addresses from set of measurement targets
def inspect_targets(targets_orig,privates_orig,blacklisted_orig, logger=$LOG)
  targets,privates,blacklisted=targets_orig.clone,privates_orig.clone,blacklisted_orig.clone
  raise "#{targets.class} not an Array!\n #{targets_orig.class}\n #{targets_orig.inspect}\n #{targets.inspect}" if !targets.respond_to?(:delete_if)
  targets.delete_if {|target| 
    # to handle cases like timestamp when the request is actually an array
    # we assume the first is the destination and do not blacklist based on
    # the other values
    if target.class==Array
      target=target.at(0)
    end
    privates.include?(target) or blacklisted.include?(target) or
    if Inet::in_private_prefix?(target)
      privates << target
      logger.puts "Removed private address #{target} from targets"
      true
    elsif Inet::in_blacklisted_prefix?(target)
      blacklisted << target
      logger.puts "Removed blacklisted address #{target} from targets"
      true
    else
      false
    end
  }
  return targets, privates, blacklisted
end


class TruncatedTraceFileException < RuntimeError
  attr :partial_results
  def initialize(partial_results)
    @partial_results=partial_results
  end
end
# return an array of recordroutes, where each is [dst,hops array, rtt, ttl]
# will throw TruncatedTraceFileException for malformed files
def convert_binary_recordroutes(data, print=false)
  offset=0
  recordroutes=[]
  #while not probes.eof?
  while not offset>=data.length
    rr=data[offset,72].unpack("N3LfL2N9L2")
    offset += 72
    if rr.nil? or rr.include?(nil)
      raise TruncatedTraceFileException.new(recordroutes), "Error reading header", caller
    end
    dst=Inet::ntoa(rr.at(0))
    rtt=rr.at(4)
    ttl=rr.at(5)
    hops=rr[7..15].collect{|x| Inet::ntoa(x)}

    recordroutes << [dst,hops,rtt,ttl]
    if print
      $stdout.puts "#{dst} #{rtt} #{hops.join(" ")}"
    end
  end
  return recordroutes
end

# take data, a string read in from an iplane-format binary trace.out file
# return an array of traceroutes, where each is [dst,hops array, rtts array,
# ttls array]
# will throw TruncatedTraceFileException for malformed files
# if you give it print=true AND a block, will yield the print string to the
# block, so you can for instance give it the source
def convert_binary_traceroutes(data, print=false)
  offset=0
  traceroutes=[]
  while not offset>=data.length
    header=data[offset,16].unpack("L4")
    offset += 16
    if header.nil? or header.include?(nil) 
      raise TruncatedTraceFileException.new(traceroutes), "Error reading header", caller
    end
    client_id=header.at(0)
    uid=header.at(1)
    num_tr=header.at(2)
    record_length=header.at(3)
    (0...num_tr).each{|traceroute_index|
      tr_header=data[offset,8].unpack("NL")
      offset += 8
      if tr_header.nil? or tr_header.include?(nil)
        raise TruncatedTraceFileException.new(traceroutes), "Error reading TR header", caller
      end
      dst=Inet::ntoa(tr_header.at(0))
      numhops=tr_header.at(1)
      hops = []
      rtts = []
      ttls = []
      last_nonzero=-1
      (0...numhops).each{|j|
        hop_info=data[offset,12].unpack("NfL")
        offset += 12
        if hop_info.nil? or hop_info.include?(nil)
          raise TruncatedTraceFileException.new(traceroutes), "Error reading hop", caller
        end
        ip = Inet::ntoa(hop_info.at(0))
        rtt = hop_info.at(1)
        ttl = hop_info.at(2)
        if (ttl > 512)
          raise TruncatedTraceFileException.new(traceroutes), "TTL>512, may be corrupted", caller
        end
        if ip!="0.0.0.0"
          last_nonzero=j
        end
        hops << ip
        rtts << rtt
        ttls << ttl

      }
      if last_nonzero>-1
        traceroutes << [dst,hops,rtts,ttls]
        if print
          tr_s="#{dst} #{last_nonzero+1} #{hops[0..last_nonzero].join(" ")}"
          if block_given?
            yield(tr_s)
          else 
            $stdout.puts "tr_s"
          end 
          #puts "#{ARGV[1..-1].join(" ")} #{dst} #{last_nonzero+1} #{hops[0..last_nonzero].join(" ")}"
        end
      end

    }
  end
  return traceroutes
end

class UnionFind
  def initialize()
    @up=Hash.new("root")
    # not currently using weights
    @weight=Hash.new(1)
  end

  attr_reader :up, :weight

  def find(x)
    if @up[x]=="root"
      @up[x] = "root" # explicitly add it in case this was just the default
      return x;
    else 
      return self.find(@up[x]);
    end
  end

  def union(x,y)
    rx = self.find(x)
    ry = self.find(y)
    if rx != ry
      @up[rx] = ry
    end
  end

  # return an array of arrays, where each is a grouping
  def groups
    c = Hash.new
    @up.keys.each{|key|
      c.append(self.find(key),(key))
    }
    return c.values
  end
end

class Array
  # convert to a hash
  # if given a param, assigns that value to everything
  # else yields each value to the block
  # note that:
  # a) it does not give a real default to the hash
  # b) you cannot give nil as the default value
  def to_h(default=nil)
    inject({}) {|h,value| h[value] = default || yield(value); h }
  end
end

class Hash
  # can also do something like this:
  # def initialize 
  #      @map = Hash.new { |hash, key| hash[key] = [] } 
  # end 
  #
  # def addToList(key, val) 
  #      @map[key] << val 
  # end 
  # for when the keys hash to an array of values
  # add the value to the array, creating a new array when necessary
  def append (key, value )
    if not self.has_key?(key)
      self[key] = Array.new
    end
    self[key] << value
  end
  # for when the keys hash to their own hash
  # create a new hash when necessary (default false)
  # and add the new k/v pair)
  def append_to_hash (key, intermediatekey, value )
    if not self.has_key?(key)
      self[key] = Hash.new(false)
    end
    (self[key])[intermediatekey] = value
  end
  # for when the keys hash to their own hash
  # and each intermediate key hashes to an array of values
  # create a new hash when necessary (default Array.new)
  # and append the new value
  # this may be broken?
  def append2_to_hash (key, intermediatekey, value )
    if not self.has_key?(key)
      self[key] = Hash.new(Array.new)
    end
    self[key].append(intermediatekey,value)
  end

  # could instead do:
  # @h3 = Hash.new{ |h,k| h.has_key?(k) ? h[k] : k }
  # given a key,  return the value if the key is in the hash
  # otherwise return the key
  def getValueOrIdentity( key )
    if self.has_key?(key)
      return self[key]
    else
      return key
    end
  end
end

#$ip2cluster = Hash.new{ |h,k| h.has_key?(k) ? h[k] : ( h.has_key?(k.split(".")[0..2].join(".") + ".0/24") h[k.split(".")[0..2].join(".") + ".0/24"] : k.split(".")[0..2].join(".") + ".0/24") }
$ip2cluster = Hash.new{ |h,k| h.has_key?(k) ? h[k] : k }
$cluster2ips = Hash.new(Array.new)
def loadClusters(clsfn)
  File.open( clsfn, "r" ){|f|
    linenum=1
    f.each_line{|line|
      info = line.chomp("\n").split(" ")
      # cluster=linenum
      cluster=info.at(0)
      $cluster2ips[cluster] = info
      info.each{|ip|
        $ip2cluster[ip] = cluster
        # $cluster2ips.append( info.at(0), ip )
      }
      linenum+=1
    }
  }
end

# mappings for PL nodes: hostname to IP and back
# some VPs, especially mlab ones, have more than one IP address
# if the $PL_HOSTNAMES_W_IPS includes double entries for these, we map from
# all IPs to the hostname, but we map from the hostname only to the first IP
# in the file
if $pl_ip2host.nil? then $pl_ip2host = Hash.new{ |h,k| (k.respond_to?(:downcase) && h.has_key?(k.downcase)) ? h[k.downcase] : k } end
if $pl_host2ip.nil? then 
  $pl_host2ip = Hash.new do |h,k|
   result = nil
   if (k.respond_to?(:downcase) && h.has_key?(k.downcase))
      result =h[k.downcase]
#   else 
#       raise "Does not contain hostname: #{k}" 
   end

   result
end
end

def loadPLHostnames
  File.open( $PL_HOSTNAMES_W_IPS.chomp("\n"), "r"){|f|
    f.each_line{|line|
      info = line.chomp("\n").split(" ")
      next if info.empty? or !info[1].respond_to?(:downcase) or !info[0].respond_to?(:downcase)
      $pl_ip2host[ info.at(1).downcase ] = info.at(0)
      next if $pl_host2ip.has_key?(info.at(0)) # skip duplicate hostnames
      $pl_host2ip[ info.at(0).downcase ] = info.at(1)
    }
  }
end

# mappings from PL hostname to site; can be used to check if 2 are at the same
# site in order to exclude probes from the target site, say
if $pl_ip2host.nil? or $pl_host2site.nil? then
  $pl_host2site = Hash.new{ |h,k| (k.respond_to?(:downcase) && h.has_key?(k.downcase)) ? h[k.downcase] : k }
end

def loadPLSites
  File.open( $PL_HOSTNAMES_W_SITES.chomp("\n"),"r"){|f|
    f.each_line{|line|
      info = line.chomp("\n").split(" ")
      next if info[0].nil?
      $pl_host2site[ info.at(0).downcase ] = info.at(1)
    }
  }
end

# set of PL spoofers
$spoofers=Array.new
def loadSpoofers(fn)
  File.open(fn.chomp("\n"),"r"){|f|
    f.each_line{|line|
      $spoofers << line.chomp("\n")
    }
  }
end

# set of PL ts spoofer sites
$ts_spoofer_sites=Array.new
def loadTSSpoofers(fn,is_hosts=true)
  File.open(fn.chomp("\n"),"r"){|f|
    f.each_line{|line|
      if is_hosts
        $ts_spoofer_sites << $pl_host2site[line.chomp("\n")]
      else
        $ts_spoofer_sites << line.chomp("\n")
      end
    }
  }
end

class Log
  def initialize
    @output_stream = $stderr
    @max_alert = 1
  end

  attr_accessor :output_stream, :max_alert

  def set_max_alert_level(newlevel)          
    @max_alert = newlevel
  end

  def email(address,msg,date,subject="")
    msg = "From: revtr@cs.washington.edu\nSubject: [revtr_error] #{subject.gsub(/'/, "\"")}\n\n" + msg.gsub(/'/, "\"") + "\n" + date.gsub(/'/, "\"")
    `echo \'#{msg}\' | /usr/sbin/sendmail #{address}`
  end

  def puts(msg, level=3)
    $stderr.puts msg if($DEBUG)
    
    date=Time.new.strftime("%Y/%m/%d.%H%M.%S")
    subject=""
    if msg.class==Array 
      subject=msg.at(0)
      msg=msg.at(1)
    end
    if (level == 1 && @max_alert <= 1)
      $TEXT_ADDRESSES.each {|sms|
        email(sms, msg, date, subject)
      }
    end
    if (level <= 2 && @max_alert <= 2)
      $EMAIL_ADDRESSES.each {|email|
        email(email, msg, date, subject)
      }
    end
        p = (msg.class == "Array" ? msg : msg.to_s).gsub(/\n/,"\n#{date} ")
    @output_stream.puts date + " " + p
  end

  def close
  # empty, but here for signature compatibility with subclasses
  end

end

class NewLog < Log

    def initialize(appname="revtr")
        super()
        Syslog.open(appname, (Syslog::LOG_PID | Syslog::LOG_NDELAY), Syslog::LOG_LOCAL1)
    end

    attr_accessor :logIDs

    def puts(msg, level=3)
        date=Time.new.strftime("%Y/%m/%d.%H%M.%S")
    subject=""
    if msg.class==Array 
      subject=msg.at(0)
      msg=msg.at(1)
    end
        if (level <= 2 && @max_alert <= 2)
            $EMAIL_ADDRESSES.each {|email|
                email(email, msg.to_s, date, subject)
            }
        end
        p = msg.class == "Array" ? msg : msg.to_s
        p = p.gsub(/%/, "%%")
    begin
      if(logIDs.nil?)
          Syslog.debug(p)
      else
        Syslog.debug(logIDs + ": " + p)
      end
    rescue Exception => e
      email("revtr@cs.washington.edu", "#{p}\n#{e.to_s}\n#{e.backtrace}"  , Time.now.to_s, "Logger error!")
    end
    end

end

# uses Logger
class LoggerLog < Log
  extend Forwardable
  def_delegators :@myLog,:<<,:add,:close,:datetime_format,:datetime_format=,:debug,:debug?,:error,:error?,:fatal,:fatal?,
      :format_message,:format_severity,:info,:info?,:log,:level,:level=,:unknown,:warn,:warn?,:close,:formatter,:formatter=

  alias :puts :info
  def initialize(appname="revtr.log")
      super()
      @myLog = Logger.new( appname, 10, 1024000000 )
      @myLog.formatter = nil # ActiveRecord overwrites this! We want the default formatter behavior...
      #@myLog.datetime_format = "%Y/%m/%d.%H%M.%S"  
  end

  def puts(message, level=nil)
      @myLog.info(message)
  end
end


if $0 == __FILE__
    puts Inet::prefix("1.2.3.4", 4)
    puts Inet::ntoa(Inet::aton("1.2.3.4"))
    puts Inet::in_private_prefix?("1.2.3.4")
    puts Inet::in_private_prefix?("192.168.1.1")
    puts Inet::in_private_prefix?("0.0.0.0")
end
