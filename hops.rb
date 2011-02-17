class Hop
    attr_accessor :ip, :dns, :ttl, :asn, :ping_responsive, :last_responsive, :formatted
    def initialize
        @ping_responsive = false
        @last_responsive = false
    end

    def <=>(other)
        @ttl <=> other.ttl
    end
end

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
       s = "#{@ttl}.  #{@formatted} (pingable from S?: #{@ping_responsive}) [historically pingable?: #{@last_responsive or "false"}]"
       s << "\n  <ul type=none>\n"
       reverse_path.each do |hop|
           s << "    <li> #{hop}</li>\n"
       end
       s << "  </ul>\n"
       s
    end
end

class ReverseHop < Hop
    attr_accessor :valid_ip
    def initialize(formatted, ipInfo)
        $stderr.puts "formatted was nil!" if formatted.nil?
        @formatted = formatted
        # could be a true hop, or could be "No matches in the past 1440 minutes!"
        match = formatted.scan(/^[ ]*(\d+)(.*)\((.*)\).*/)

        if match.empty?
            @ttl = -1
            @dns = ""
            @ip = "0.0.0.0"
            @valid_ip = false
        else
            @ttl = match[0][0]
            @dns = match[0][1].strip
            @ip = match[0][2]
            @valid_ip = true
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
        @ping_responsive = (@ip != "0.0.0.0")
        @last_responsive = (@ip != "0.0.0.0")
    end

    def to_s()
        "#{@ttl}.  #{(@formatted.nil?) ? "" : @formatted.clone}"
    end
end
