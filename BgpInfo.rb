#!/homes/network/revtr/ruby-upgrade/bin/ruby
#
# Keeps an in-memory Trie of origin_as_mapping's IP address information
# For example, retrieve ASNs or prefixes for a given IP

# XXX why Dave's, and not mine?
require_relative 'utilities.rb'
require 'rpatricia'

class BgpInfo
    def initialize(originAsMapping="/homes/network/revtr/spoofed_traceroute/data/origin_as_mapping.txt")
        @trie = buildTrie(originAsMapping)
    end

    def getPrefix(dotted)
        result = grabResult(dotted)
        (result) ? prefixString(result) : nil
    end

    # returns a string representation of the ASN advertising the given IP address
    # returns nil if no ASN advertised
    # returns underscore delimited string if multiple ASes advertised the IP
    def getASN(dotted)
        result = grabResult(dotted)
        (result) ? result.data : nil
    end

    # returns [advertised prefix, ASN]
    def getInfo(dotted)
        result = grabResult(dotted)
        (result) ? [prefixString(result), result.data] : nil
    end

    private 

    def grabResult(dotted)
        raise ArgumentError.new "Invalid IP Address: #{dotted.inspect}" \
            unless dotted =~ /^\d+\.\d+\.\d+\.\d+$/
        @trie.search_best(dotted)
    end

    # precondition: !node.nil?
    def prefixString(node)
        "#{node.prefix}/#{node.prefixlen}"
    end

    def buildTrie(originAsMapping)
        raise LoadError.new "Couldn't load file #{originAsMapping}" \
            unless File.readable? originAsMapping

        pt = Patricia.new
        File.foreach(originAsMapping) do |line|
            raise ArgumentError.new "Couldn't parse line: #{line}" \
                unless line =~ /^\d+\.\d+\.\d+\.\d+\/\d+\s+\S+$/
           
            advertisedPrefix, asn = line.chomp.split
            mockIp, mask = advertisedPrefix.split('/')
            next if Inet::in_private_prefix? mockIp
            next if mask.to_i > 24 or mask.to_i < 4
            next if asn == "*"
            
            # TODO: asn = asn.to_i? what about '*'s though?
            # hmmm, the trie doesn't accept ints
            pt.add advertisedPrefix, asn
        end
        pt
    end
end

if $0 == __FILE__
    bgpInfo =  BgpInfo.new 
    ip = (ARGV.shift or "128.6.45.1")
    puts "#{ip} is part of #{bgpInfo.getPrefix(ip)}"
    puts "ASN is #{bgpInfo.getASN(ip)}"
    puts bgpInfo.getPrefix("0.0.0.0")
    puts "Yay!"
end
