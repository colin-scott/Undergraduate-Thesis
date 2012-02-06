#!/homes/network/revtr/jruby/bin/jruby

$: << "./"

# Very similar to check_up_and_start_vps.rb (in fact, completely redundant),
# but rather than troubleshooting problems, simply reboot the VPs.
# TODO: merge with check_up_and_start_vps.rb

require 'isolation_mail'
$PL_HOSTNAMES_W_IPS = "/homes/network/revtr/spoofed_traceroute/data/pl_hostnames_w_ips.txt"
$VP_SLICE = "uw_revtr2"


begin

    require 'fileutils'
    require 'sql'
    require 'date'
    require 'slice'

rescue Exception

    email_and_die

end

begin 
   
    # Generate both a Hash pointing VPs to uptime stats, and a file with all
    # of the VPs we want to check
    $vps = Hash.new
    if ARGV[0] != nil
        File.open(ARGV[0]) { |infile|
            while (line = infile.gets)
                vp = IsolationVantagePoint.find(:first, :conditions => {:vantage_point => line.strip})
                if (vp == nil) then
                    hostname = line.strip
                    ip = ""
                    File.open(File::expand_path($PL_HOSTNAMES_W_IPS)) { |f|
                        while (ipmf_line = f.gets)
                            pair = ipmf_line.strip.split(" ")
                            if (pair[0] == hostname) then
                                ip = pair[1]
                                break
                            end
                        end
                    }
                    if (ip == "") then 
                        begin
                            ip = Socket::getaddrinfo(hostname,nil)[0][3]
                        rescue Socket::SocketError
                            puts "No mapping for #{line.strip}, and could not resolve to an IP address."
                            next
                        end
                    end
                    vp = IsolationVantagePoint.new(:vantage_point => hostname, :IP => ip)
                    puts "Adding a VP to the database: #{hostname}, #{ip}"
                    vp.save!
                end
                vp.last_updated = DateTime.now.to_s.tr("T"," ").split("-")[0..2].join("-")
                $vps[vp.vantage_point] = vp if vp != nil
            end
        }
    else
        # Write the VPs to a file for pptasks
        IsolationVantagePoint.find(:all, :conditions => {:active => 1}).each { |vp| 
            $vps[vp.vantage_point] = vp
        }
    end

    # Get the Slice object
    slice = Slice.new($VP_SLICE)

    slice.restart_and_check($vps.keys).each { |vp, up|
        next if !$vps.has_key? vp
        if up then
            puts "Fixed #{vp} by a simple restart."
            if !$vps[vp].controllable_after_start then
                $vps[vp].last_updated = DateTime.now.to_s.tr("T"," ").split("-")[0..2].join("-")
                $vps[vp].controllable_after_start = true
            end
            $vps[vp].save!
            $vps.delete(vp)
        end
    }
end

sleep 20
