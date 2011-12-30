
# In addition to the functionality of BgpInfo, retrieve DNS names for IP
# addresses.

require 'resolv'
require 'BgpInfo'

class IpInfo
    def initialize()
        @bgpInfo = BgpInfo.new
    end

    def get_addr(dst)
        begin
            dst_ip=Resolv.getaddress(dst)
        rescue Exception
            $stderr.puts "Unable to resolve #{dst}: #{$!}"
        end
    end

    def getASN(ip)
        @bgpInfo.getASN(ip)  
    end

    def getPrefix(ip)
        @bgpInfo.getPrefix(ip)
    end

    #returns [prefix, asn]
    def getInfo(ip)
        @bgpInfo.getInfo(ip)
    end

    def resolve_dns(dst, dst_ip)
        dns = ((dst_ip==dst) ? "#{Resolv.getname(dst) rescue dst}" : "#{dst}")
    end

    def format(ip, dns=nil, asn=nil)
        dns = resolve_dns(ip, ip) if dns.nil?
        asn = @bgpInfo.getASN(ip) if asn.nil?
        prefix = @bgpInfo.getPrefix(ip)
        "#{dns} (#{ip}) [#{prefix}, ASN: #{asn}]"
    end
end
