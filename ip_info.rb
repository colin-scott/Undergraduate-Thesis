require 'resolv'
require 'BgpInfo'

class IpInfo
    def initialize()
        @bgpInfo = BgpInfo.new
    end

    def get_addr(dst)
        begin
            dst_ip=Resolv.getaddress(dst)
        rescue
            $stderr.puts "Unable to resolve #{dst}: #{$!}"
        end
    end

    def getASN(ip)
        @bgpInfo.getASN(ip)  
    end

    def resolve_dns(dst, dst_ip)
        dns = ((dst_ip==dst) ? "#{Resolv.getname(dst) rescue dst}" : "#{dst}")
    end

    def format(ip, dns=nil, asn=nil)
        dns = resolve_dns(ip, ip) if dns.nil?
        asn = @bgpInfo.getASN(ip) if asn.nil?
        "#{dns} (#{ip}) [ASN: #{asn}]"
    end
end
