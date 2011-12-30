#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << "./"

require '../spooftr_config'
require 'isolation_mail'
require 'resolv'

begin

    require 'sql'

rescue Exception

    email_and_die

end

# This script takes a file and an arbitrary number of column=value pairs.
# The first input is a path to a file. This script will go through each 
# line of this file and do the following:
# 1) Try to find a record with the same hostname in the database.
# 2) If we find a database record, and the input file has an specified IP
# and the database record conflicts with the input file, correct the
# database's entry.
# 3) If we can't find a database record, then add one. The corresponding IP
# will be from a) An entry in the input file, b) An entry in the global IP
# mapping file, c) An attempt to resolve the hostname. If none of these
# methods work, we won't add the record.
# 4) For each column=value pair passed to this script, we will set the 
# database column corresponding to that parameter to the value passed.

File.open(ARGV[0]) { |infile|
    while (line = infile.gets)
        # Parse this line
        entry = line.strip.split(" ")
        hostname = entry[0]
        ip = ""
        ip = entry[1] if (entry.length > 1)
        # Try to find this hostname in the database
        vp = IsolationVantagePoint.find(:first, :conditions => {:vantage_point => hostname})
        # Correct the DB's IP if it doesn't match
        vp.IP = ip if (vp != nil && ip != "" && vp.IP != ip)
        if (vp == nil) then
            # If we weren't given an IP, get it from the mapping file
            if (ip == "") then
                File.open(File::expand_path($PL_HOSTNAMES_W_IPS)) { |f|
                    while (ipmf_line = f.gets)
                        pair = ipmf_line.strip.split(" ")
                        if (pair[0] == hostname) then
                            ip = pair[1]
                            break
                        end
                    end
                }
                # If the IP isn't in the mapping file, try to resolve it
                if (ip == "") then
                    begin
                        ip = Socket::getaddrinfo(hostname,nil)[0][3]
                    rescue SocketError
                        puts "No mapping for #{line.strip}, and could not resolve to an IP address."
                        next
                    end
                end
            end
            vp = IsolationVantagePoint.new(:vantage_point => hostname, :IP => ip)
            puts "Adding a VP to the database: #{hostname}, #{ip}"
        end
        if (vp != nil && ARGV.length > 1) then
            ARGV[1..-1].each { |arg|
                pair = arg.split("=")
                vp[pair[0]] = pair[1] if vp.has_attribute?(pair[0])
            }
        end
        vp.save! if vp != nil
    end
}
