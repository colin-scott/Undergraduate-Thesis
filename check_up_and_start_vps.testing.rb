#!/homes/network/revtr/ruby/bin/ruby

#require 'config_website'
require '../spooftr_config'
require 'mail'

begin

    require 'fileutils'
    require 'sql'
    require 'date'
    require 'slice'

rescue

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

    # XXX
    file = "/tmp/#{$$}.bs" 
    File.open(file, 'w') { |f| f.write($vps.keys.join("\n")) }
    `#{$REV_TR_TOOL_DIR}/perl/bootstrap_revtr_nodesX_for_sliceY.pl #{file} #{$VP_SLICE} ; #{$REV_TR_TOOL_DIR}/perl/upgrade_revtr_to_vp_nodesX_for_sliceY.pl #{file} #{$VP_SLICE};`

    # Get the Slice object
    slice = Slice.new($VP_SLICE)

    $stderr.puts("FIRST CHECK: can we SSH into the slivers?")

    slice.hostname_check($vps.keys).each { |vp, up| 
        next if !$vps.has_key? vp
        if $vps[vp].sshable != up then
            $vps[vp].last_updated = DateTime.now.to_s.tr("T"," ").split("-")[0..2].join("-")
            $vps[vp].sshable = up
        end
        if !up then
            $vps[vp].save!
            puts "#{$vps.delete(vp).vantage_point} not sshable..."
        end
    }

    exit if ($vps.length == 0)
    
    $stderr.puts("SECOND CHECK: can we control the slivers?")

    slice.controller_check($vps.keys).each { |vp, up|
        next if !$vps.has_key? vp
        if $vps[vp].controllable != up then
            $vps[vp].last_updated = DateTime.now.to_s.tr("T"," ").split("-")[0..2].join("-")
            $vps[vp].controllable = up
        end
        if up then
            $vps[vp].save!
            puts "#{$vps.delete(vp).vantage_point} not controllable..."
        end
    }

    exit if ($vps.length == 0)

    # Don't want to be confusing...
    $vps.each { |str, vp| 
        puts "Looking at #{str}..."
        vp.at_problem = false
        vp.ruby_problem = false
        vp.sudo_problem = false
    }
    
    $stderr.puts("THIRD CHECK: is something wrong with at?")

    badAt = Array.new
    goodAt = Array.new
    
    # Let's first see if the "at" command is working
    slice.if_outputs_hostname('rm -f /tmp/hostname; echo "hostname --fqdn > /tmp/hostname" | at now  && sleep 1; cat /tmp/hostname ;', $vps.keys).each { |vp, output|
        next if !$vps.has_key? vp
        puts "Adding #{vp} to badAt..." if !output
        badAt << vp if !output
    }

    # Try to restart the atd, and then try again
    slice.if_outputs_hostname('if [ `ps aux | grep atd | grep -v grep | wc -l` -eq 0 ]; then sudo /sbin/service atd start ; fi; rm -f /tmp/hostname; echo "hostname --fqdn > /tmp/hostname" | at now  && sleep 1; cat /tmp/hostname ;', badAt).each { |vp, output|
        next if !$vps.has_key? vp
        if output then
            puts "Looks like #{vp} fixed? We restarted atd."
            goodAt << vp
            badAt.delete(vp)
        end
    }
    
    # Try to install at, and then try again
    slice.if_outputs_hostname('sudo yum -y install at && sudo /sbin/service atd start ; rm -f /tmp/hostname; echo "hostname --fqdn > /tmp/hostname"| at now && sleep 1; cat /tmp/hostname ;', badAt).each { |vp, output|
        next if !$vps.has_key? vp
        if output then
            puts "Looks like #{vp} fixed? We reinstalled at."
            goodAt << vp
            badAt.delete(vp)
        end
    }
    
    # Is it working now?
    if goodAt.length > 0 then
        slice.restart_and_check(goodAt).each { |vp, up|
            next if !$vps.has_key? vp
            if up then
                puts "Yup, #{vp} fixed!"
                if !$vps[vp].controllable_after_start then
                    $vps[vp].last_updated = DateTime.now.to_s.tr("T"," ").split("-")[0..2].join("-")
                    $vps[vp].controllable_after_start = true
                end
                $vps[vp].save!
                $vps.delete(vp)
            else
                puts "#{vp} still not working, but it's not because of at."
            end
        }
    end

    # Deal with the remainders
    badAt.each { |vp|
        puts "Giving up on #{vp}..."
        $vps[vp].at_problem = true
        if $vps[vp].controllable_after_start then
            $vps[vp].last_updated = DateTime.now.to_s.tr("T"," ").split("-")[0..2].join("-")
            $vps[vp].controllable_after_start = false
        end
        $vps[vp].save!
        $vps.delete(vp)
    }

    $stderr.puts("FOURTH CHECK: is something wrong with Ruby?")
    badRuby = Array.new
    goodRuby = Array.new
    
    # Check if Ruby is around
    slice.if_output('which ruby', $vps.keys, 90).each { |vp, output|
        next if !$vps.has_key? vp
        puts "Adding #{vp} to badRuby..." if !output
        badRuby << vp if !output
    }
    
    # Try to install Ruby
    slice.if_output('sudo yum -y install ruby ; which ruby', badRuby).each { |vp, output|
        next if !$vps.has_key? vp
        if output then
            puts "Looks like #{vp} fixed? We reinstalled Ruby."
            goodRuby << vp
            badRuby.delete(vp)
        end
    }

    # Is it working now?
    if goodRuby.length > 0 then
        slice.restart_and_check(goodRuby).each { |vp, up|
            next if !$vps.has_key? vp
            if up then
                puts "Yup, #{vp} fixed!"
                if !$vps[vp].controllable_after_start then
                    $vps[vp].last_updated = DateTime.now.to_s.tr("T"," ").split("-")[0..2].join("-")
                    $vps[vp].controllable_after_start = true
                end
                $vps[vp].save!
                $vps.delete(vp)
            else
                puts "#{vp} still not working, but it's not because of ruby."
            end
        }
    end
    
    # Deal with the remainders
    badRuby.each { |vp|
        puts "Giving up on #{vp}..."
        $vps[vp].ruby_problem = true
        if $vps[vp].controllable_after_start then
            $vps[vp].last_updated = DateTime.now.to_s.tr("T"," ").split("-")[0..2].join("-")
            $vps[vp].controllable_after_start = false
        end
        $vps[vp].save!
        $vps.delete(vp)
    }

    $stderr.puts("FIFTH CHECK: okay, so... maybe sudo?")

    badSudo = Array.new

    slice.if_outputs_hostname('sudo hostname --fqdn ', $vps.keys).each { |vp, output|
        next if !$vps.has_key? vp
        if !output then
            puts "#{vp} has a bad sudo! Giving up..."
            $vps[vp].sudo_problem = true
            if $vps[vp].controllable_after_start then
                $vps[vp].last_updated = DateTime.now.to_s.tr("T"," ").split("-")[0..2].join("-")
                $vps[vp].controllable_after_start = false
            end
            $vps[vp].save!
            $vps.delete(vp)
            badSudo << vp
        end
    }
    
    $stderr.puts("SIXTH CHECK: let's try restarting the issuer.")

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
    
    $stderr.puts("SEVENTH CHECK: I give up. Try boostrapping, and then we're outta here.")
   
    file = "/tmp/#{$$}.bs" 
    File.open(file, 'w') { |f| f.write($vps.keys.join("\n")) }
    `#{$REV_TR_TOOL_DIR}/perl/bootstrap_revtr_nodesX_for_sliceY.pl #{file} #{$VP_SLICE} ; #{$REV_TR_TOOL_DIR}/perl/upgrade_revtr_to_vp_nodesX_for_sliceY.pl #{file} #{$VP_SLICE};`
    sleep(300)
    slice.restart_and_check($vps.keys).each { |vp, up|
        next if !$vps.has_key? vp
        puts "Fixed #{vp} by bootstrapping the codebase." if up
        if $vps[vp].controllable_after_start != up then
            $vps[vp].last_updated = DateTime.now.to_s.tr("T"," ").split("-")[0..2].join("-")
            $vps[vp].controllable_after_start = up
        end
        $vps[vp].save!
    }
    File.delete(file) if File.exists?(file)
    
    $vps.keys.each { |vp| puts "No idea what's going on with #{vp}..." }
    
    # Email us in a batch 
    #Emailer.check_up_vps_issue(badSudo, "sudo") if badSudo.length > 0
    #Emailer.check_up_vps_issue(badAt - badSudo, "at") if (badAt - badSudo).length > 0
    #Emailer.check_up_vps_issue(badRuby - badSudo, "ruby") if (badRuby - badSudo).length > 0
    
end
