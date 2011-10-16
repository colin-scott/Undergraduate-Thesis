#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../../")

require 'direction'
require 'log_iterator'
require 'mkdot'
require 'hops'
#require 'irb'
require 'utilities'
require 'config_zooter'
ipInfo = IpInfo.new
$OUTDIR = "/homes/network/revtr/spoofed_traceroute/reverse_traceroute/data_analysis/pl_pl_outages/"
filter_fail_counts = Hash.new{|h,k| h[k] = 0}
log_count = 0
bad_outage_counts = Hash.new{|h,k| h[k]=0}
ok_count = 0
confirmed = 0
check_by_hand = []

path = "#{$OUTDIR}interesting/"

    if File.exists? path then
        d = Dir.new(path)
        d.each{|file|
            next if file == "." or file == ".."
            next if not file.include? "bin"

            begin 
             f=  File.open(path+file, 'r') 
            outage = Marshal.load(f.read)
            f.close
            rescue ArgumentError
                puts "Failed: "+ file
                puts $!.to_s
                exit 
               end

            # strange issues:
            # suspect is the source or dest
            ok = false
            outage.suspected_failures.each{|k,hops|
                hops.each{|hop|
                # hop is type Hop
                ip = nil
                if hop.is_a? String then ip = hop
                elsif hop.is_a? Hop then ip = hop.ip
                end
                if ip == outage.dst
                    puts "ERROR: Suspect is the destination (#{file})"
                    bad_outage_counts[:suspect_is_dest]+=1
                elsif ipInfo.getASN(ip) == ipInfo.getASN(outage.dst)
                    puts "ERROR: Suspect is the destination AS (#{file})"
                    bad_outage_counts[:suspect_is_dest_as]+=1
                elsif ipInfo.getPrefix(ip) == ipInfo.getPrefix(outage.dst)
                    puts "ERROR: Suspect is the destination prefix (#{file})"
                    bad_outage_counts[:suspect_is_dest_pfx]+=1
                elsif ip == $pl_host2ip[outage.src]
                    puts "ERROR: Suspect is the source (#{file})"
                    bad_outage_counts[:suspect_is_src]+=1
                elsif ipInfo.getASN(ip) == ipInfo.getASN($pl_host2ip[outage.src])
                    puts "ERROR: Suspect is the source AS (#{file})"
                    bad_outage_counts[:suspect_is_src_as]+=1
                elsif ipInfo.getPrefix(ip) == ipInfo.getPrefix($pl_host2ip[outage.src])
                    puts "ERROR: Suspect is the source prefix (#{file})"
                    bad_outage_counts[:suspect_is_src_pfx]+=1
                else ok=true
                end
                }
            }

            if not ok then next end
            ok_count+=1
            # if failure on reverse path
            if outage.suspected_failures.include? Direction.REVERSE
                last_hop = []
                if outage.dst_tr.valid?
                    last_hop << outage.dst_tr.last_non_zero_ip
                    puts "Dst tr: last hop: #{last_hop}"
                end
                if outage.dst_spoofed_tr.valid?
                    last_hop << outage.dst_spoofed_tr.last_non_zero_ip
                    puts "Dst spoofed tr: last hop: #{last_hop}"

                end
               puts file
               puts "Suspected failure: #{outage.suspected_failures[Direction.REVERSE]}"
               puts "Last hop: #{last_hop} #{ipInfo.getASN(last_hop)}"
               #puts "Spoofed tr:\n#{outage.spoofed_tr}" if outage.spoofed_tr.valid?

            elsif outage.suspected_failures.include? Direction.FORWARD
                last_hop = []
                if outage.tr.valid?
                    last_hop << outage.tr.last_non_zero_ip
                end
                if outage.spoofed_tr.valid?
                    last_hop << outage.spoofed_tr.last_non_zero_ip
                end

                puts file

                dst_tr_reach = true
                # make sure dst trs didn't reach
                if outage.dst_tr.last_non_zero_ip == $pl_host2ip[outage.src] 
                    bad_outage_counts["dst_tr_reaches_src"]+=1
                    ok_count-=1   
                elsif !outage.dst_tr.last_non_zero_ip.nil? && ipInfo.getPrefix(outage.dst_tr.last_non_zero_ip) == ipInfo.getPrefix($pl_host2ip[outage.src] )
                    bad_outage_counts["dst_tr_reaches_src_pfx"]+=1
                    ok_count-=1   
                elsif !outage.dst_tr.last_non_zero_ip.nil? && ipInfo.getASN(outage.dst_tr.last_non_zero_ip) == ipInfo.getASN($pl_host2ip[outage.src] )
                    bad_outage_counts["dst_tr_reaches_src_as"]+=1
                    ok_count-=1   
                else dst_tr_reach = false
                end
                
#                if outage.dst_spoofed_tr.last_non_zero_ip == $pl_host2ip[outage.src]
#                    bad_outage_counts["dst_spoofed_tr_reaches_src"]+=1
#                    ok_count-=1
#                elsif !outage.dst_spoofed_tr.last_non_zero_ip.nil? && ipInfo.getPrefix(outage.dst_spoofed_tr.last_non_zero_ip) == ipInfo.getPrefix($pl_host2ip[outage.src])
#                    bad_outage_counts["dst_spoofed_tr_reaches_src_pfx"]+=1
#                    ok_count-=1
#                elsif !outage.dst_spoofed_tr.last_non_zero_ip.nil? && ipInfo.getASN(outage.dst_spoofed_tr.last_non_zero_ip) == ipInfo.getASN($pl_host2ip[outage.src])
#                    bad_outage_counts["dst_spoofed_tr_reaches_src_as"]+=1
#                    ok_count-=1
#                else dst_tr_reach = false
#                end

                next if dst_tr_reach

                # make sure last hop does not appear on dst tr
                dst_tr_hops = outage.dst_tr.collect{|hop| hop.ip} + outage.dst_spoofed_tr.collect{|hop| hop.ip}
                dst_tr_pfxes = dst_tr_hops.collect{|ip| ipInfo.getPrefix(ip)}.uniq
                dst_tr_ases = dst_tr_hops.collect{|ip| ipInfo.getASN(ip)}.uniq

                        passed = false
                last_hop.each{|ip|
                    #ips.each{|ip|
                        if dst_tr_hops.include? ip then
                            bad_outage_counts["suspect is reachable from dst"]+=1
                            ok_count-=1
                        elsif dst_tr_pfxes.include? ipInfo.getPrefix(ip)
                            # does the dst_tr reach an AS in the src trs?
                            src_tr_ases = (outage.tr.collect{|hop| ipInfo.getASN(hop.ip)}+outage.spoofed_tr.collect{|hop| ipInfo.getASN(hop.ip)}).uniq
                            found = false
                            (dst_tr_ases-[ipInfo.getASN(ip)]).each{|as| if src_tr_ases.include? as then found = true; break end}
                            if found then 
                                bad_outage_counts["src-reachble AS is reachable from dst"]+=1
                                ok_count-=1
                            else
                            check_by_hand << [:pfx_reachable_from_dst, file]
                            end
                        elsif dst_tr_ases.include? ipInfo.getASN(ip)
                            check_by_hand << [:as_reachable_from_dst, file]
                        else
                            passed = true
                        end
                    #}
                }
                        if passed then confirmed+=1 end

            end


        }
end


puts "OK: #{ok_count}"
puts "Confirmed: #{confirmed}"
puts "check_by_hand:\n #{check_by_hand.collect{|k,v| "#{k}\t#{v}"}.join("\n")}"
puts "#{bad_outage_counts.to_s}"
