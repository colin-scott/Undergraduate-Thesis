#!/homes/network/revtr/ruby/bin/ruby

require 'rubygems'
require 'rpatricia'

class BgpInfo
    def initialize(originAsMapping="/homes/network/revtr/spoofed_traceroute/data/origin_as_mapping.txt")
        @trie = buildTrie(originAsMapping)
    end

    def getPrefix(dotted)
        result = grabResult(dotted)
        (result) ? prefixString(result) : nil
    end

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
        raise ArgumentError.new "Invalid IP Address: #{dotted}" \
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
                    # TODO: asn = asn.to_i? what about '*'s though?
            pt.add advertisedPrefix, asn
        end
        pt
    end
end

if $0 == __FILE__
    bgpInfo =  BgpInfo.new 
    ip = ARGV.shift
    puts "#{ip} is part of #{bgpInfo.getPrefix(ip)}"
    puts "ASN is #{bgpInfo.getASN(ip)}"
    puts bgpInfo.getPrefix("0.0.0.0")
    puts "Yay!"
end
