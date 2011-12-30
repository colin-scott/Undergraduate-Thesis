#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << "./"

# Keeps an in-memory Trie of origin_as_mapping's IP address information
# For example, retrieve ASNs or prefixes for a given IP

#require 'utilities.rb'
#require 'rubygems'
#require 'trie'
#
#class Integer 
#  def to_ba(size=32) 
#    a=[] 
#    (size-1).downto(0) do |i| 
#      a<<self[i]
#    end 
#    a 
#  end 
#end 
#
#class Array
#  def to_i
#    sum = 0
#    self.reverse.each_with_index do |elt, i|
#        sum += (elt << i)
#    end
#    sum
#  end
#end
#
#class BgpInfo
#    def initialize(originAsMapping="/homes/network/revtr/spoofed_traceroute/data/origin_as_mapping.txt")
#        @trie = buildTrie(originAsMapping)
#    end
#
#    def getPrefix(dotted)
#        prefix, asn = grabResult(dotted)
#        prefix
#    end
#
#    # returns a string representation of the ASN advertising the given IP address
#    # returns nil if no ASN advertised
#    # returns underscore delimited string if multiple ASes advertised the IP
#    def getASN(dotted)
#        prefix, asn = grabResult(dotted)
#        asn
#    end
#
#    # returns [advertised prefix, ASN]
#    def getInfo(dotted)
#        grabResult(dotted)
#    end
#
#    private 
#
#    def grabResult(dotted)
#        raise ArgumentError.new "Invalid IP Address: #{dotted.inspect}" \
#            unless dotted =~ /^\d+\.\d+\.\d+\.\d+$/
#        ipBits = Inet::aton(dotted).to_ba
#        mask = 0
#        trie = @trie
#        while trie.size != 1
#           return nil if mask == 32 
#           t = t.find_prefix[mask]
#           mask += 1
#        end
#        prefix = Inet::ntoa(ipBits[0...mask].to_i)
#        ["#{prefix}/#{mask}", t.first]
#    end
#
#    def buildTrie(originAsMapping)
#        raise LoadError.new "Couldn't load file #{originAsMapping}" \
#            unless File.readable? originAsMapping
#
#        pt = Trie.new
#        File.foreach(originAsMapping) do |line|
#            raise ArgumentError.new "Couldn't parse line: #{line}" \
#                unless line =~ /^\d+\.\d+\.\d+\.\d+\/\d+\s+\S+$/
#           
#            advertisedPrefix, asn = line.chomp.split
#            mockIp, mask = advertisedPrefix.split('/')
#            mask = mask.to_i
#            next if Inet::in_private_prefix? mockIp
#            next if mask > 24 or mask < 4
#            next if asn == "*"
#
#            ipBits = Inet::aton(mockIp).to_ba[0...mask]
#            
#            # TODO: asn = asn.to_i? what about '*'s though?
#            # hmmm, the trie doesn't accept ints
#            pt.insert ipBits, asn
#        end
#        pt
#    end
#end
#
#
#if $0 == __FILE__
#    bgpInfo =  BgpInfo.new 
#    puts "frau frau!"
#    ip = (ARGV.shift or "128.6.45.1")
#    puts "#{ip} is part of #{bgpInfo.getPrefix(ip)}"
#    puts "ASN is #{bgpInfo.getASN(ip)}"
#    puts bgpInfo.getPrefix("0.0.0.0")
#    puts "Yay!"
#end
