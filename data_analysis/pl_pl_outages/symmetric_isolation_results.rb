#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../../")

require 'log_iterator'
require 'mkdot'
require 'hops'
require 'irb'
require 'utilities'
require 'config_zooter'
require 'mysql'
#$ipInfo = IpInfo.new
$OUTDIR = "/homes/network/revtr/spoofed_traceroute/reverse_traceroute/data_analysis/pl_pl_outages/"
filter_fail_counts = Hash.new{|h,k| h[k] = 0}
log_count = 0
$irb_break = true

$mysql_con = Mysql.new('bouncer.cs.washington.edu', 'revtr', 'pmep@105&rws','revtr')

def get_nearest_traceroutes(outage, datestring)
    src = outage.src
    dest = outage.dst 

    src_site = $pl_host2site[src]
    dst_site = $pl_host2site[$pl_ip2host[dest]]
    src = $pl_host2ip[src]
    year = datestring[0..3]
    month = datestring[4..5]
    day = datestring[6..7]
    time = datestring[8..9].to_i*60 + datestring[10..11].to_i 

    path = "/homes/network/ethan/failures/pl_pl_traceroutes/logs/#{year}/#{month}/#{day}/"

    src2tr = Hash.new{|h,k| h[k] = {}}
    matchDir = []
    if File.exists? path then
        d = Dir.new(path)
        d.each{|file|
            ftime = file[0..1].to_i*60 + file[1..2].to_i
            if ftime <= time + [10,outage.get_measurement_duration].max and ftime >= time-30 then
                matchDir << [file, ftime >= time ? :during : :historic] 
                break
            end
        }
        if not matchDir.length==0 then
            matchDir.each{|dir, state|
            #puts "Found #{matchDir}"
            path = path + dir + "/probes/"

            # get each trace.out file and parse, looking for traces to src
            d = Dir.new(path)
            d.each{|file|
                if file == "." or file == ".." then next end
                trsrc = file.split("_")[0].split(".")[2..-1].join(".")
                trsrc_site = $pl_host2site[trsrc]

                if not (trsrc_site==src_site or trsrc_site== dst_site) then next end
               #puts "Tr src: #{trsrc}" 

                str =  open(path+file, "rb") {|io| io.read }
                begin 
                trs = convert_binary_traceroutes(str)
                trs.each{|tr|
                   dst=tr.at(0)
                    trdst_site = $pl_host2site[$pl_ip2host[dst]]
                    #iif trdst_site == src_site then puts "Found match on src" end
                    #if trsrc_site == dst_site then puts "Foudn match on dest" end
                   if (trdst_site == src_site and trsrc_site == dst_site) or (dst_site==trdst_site and trsrc_site==src_site) then 
                   src2tr[trsrc][state] = ForwardPath.new(tr.at(1).collect{|hop| Hop.new(hop, $ipInfo)})
                   #puts "Dest: #{dst}"
                   end
                }
                rescue TruncatedTraceFileException => e
                    #puts e.to_s
                    #puts e.backtrace
                end
            }
            }
        end
    
    end

    return src2tr
end

def print_revtr_pretty(row)

    hops = []
    ps = []
    types = []
    ts = row["date"]
    30.times{|i|
        val = row["hop"+(i+1).to_s].to_i
        type = row["type"+(i+1).to_s].to_i
        case type
        when 1..2
            types << "rr"
        when 3..6
            types << "ts"
        when 7
            types << "sym"
        when 8
            types << "tr2src"
        when 9
            types << "dst-sym"
        else
            types << "unk"
        end

        hops << Inet::ntoa(val) if val > 0 or hops.length > 0 # empty hops also represented as 0
    }
    if hops.length == 0 then $stdout.puts "No hops!"; return false end
    while hops[-1]=="0.0.0.0"
        hops.pop
        types.pop
    end

    result = "From #{$pl_ip2host[Inet::ntoa(row['src'].to_i)]} to #{Inet::ntoa(row['dest'].to_i)} at #{ts}:\n"
    i = 1
    hops.each { |hop|

        # Array of ping values for this hop
        #rtt = pings[[self.src, hop]]
        #if rtt.class != Array then rtt = [rtt] end

        # We don't want to go in a big loop
        #if $prune_loops
        # next if hops_seen[hop]
        #  hops_seen[hop]=true
        #end

        # Get the hostname
        presentation = Resolv.getname(hop) rescue ""

        # Get the technique
        #technique = first ? symbol : "-" + symbol
        #first = false

        # Add the line

        result += "#{i.to_s.rjust(2)}  #{presentation} (#{hop})".ljust(120) + "#{types[i-1]}\n"

        #  if hop == "0.0.0.0" or hop == "\*"
        #    result += "#{i.to_s.rjust(2)}  * * *".ljust(120) + " #{technique}\n"
        #  elsif rtt == [] or rtt==[nil]
        #    result += "#{i.to_s.rjust(2)}  #{presentation} (#{hop}) *".ljust(120) + "  #{technique}\n"
        #  else
        #    rtt = rtt[0..2] if rtt.length > 3
        #    result += "#{i.to_s.rjust(2)}  #{presentation} (#{hop}) #{rtt.join(" ms ")} ms".ljust(120) + " #{technique}\n"
        #  end

        # Increment the counter
        i += 1
    }

    $stdout.puts result
    return true
end

total = 0
dst_tr_working = 0
dst_spoofed_tr_working = 0
passed = 0
found_help = 0
used_help = 0
att_passed = 0
passed_filter_no_dst_tr = 0 
cases_of_interest = []
$exit_loop = false
month2pathinfo2count = Hash.new{|h,k| h[k] = Hash.new{|h1,k1| h1[k1] = 0}}
#analyzer = FailureAnalyzer.new($ipInfo, LoggerLog.new("./logger.out"))
LogIterator::iterate_all_logs do  |outage|
    month = nil
    if not outage.nil? and not outage.file.split("_").length !=2 then puts "Bad file #{outage.file}" if not outage.nil?
    else
        datestring = outage.file.split("_")[2]
        year = datestring[0..3]
        month = datestring[4..5]
        day = datestring[6..7]
        time = datestring[8..9].to_i*60 + datestring[10..11].to_i 
    end
   break if $exit_loop
    if FALSE
    $outage = outage
    if $irb_break and (((month.nil? or month.to_i < 8) and \
                                      (outage.direction == Direction.REVERSE or not (outage.direction.to_s=~/reverse/).nil?)) \
                                  or outage.direction.nil? or \
                       (outage.direction.is_a? String and not (outage.direction=~/working/).nil? and not (outage.direction=~/forward/).nil?) or \
        (not outage.direction.is_a? Direction and not outage.direction.is_a? String)) then 
        if month.nil? then IRB.start end
        puts $outage.file
        puts $outage.direction
        puts $outage.direction.class
        puts $outage.dst_tr
        puts $outage.dst_spoofed_tr
        IRB.start 
        else
        next
        end
    end

    if FALSE
    # record stats for reverse outages
    if not outage.nil? and (outage.is_a? SymmetricOutage or outage.symmetric) and \
        (not outage.suspected_failure.is_a? String or (outage.suspected_failure=~/resolved/).nil?) 
        if month.nil? then month = "nil" end
         if not outage.historical_revtr.valid? 
             month2pathinfo2count[month][:no_revtr] += 1
         else 
             $outage = outage
             IRB.start if month.to_i>0 and month.to_i < 8    
             month2pathinfo2count[month][:revtr]+=1   
         end
        
    end
    end

    if outage.symmetric and not (outage.direction.to_s=~/reverse/).nil? and not outage.suspected_failure.nil? \
       and not outage.suspected_failure.ip == outage.dst 
        $outage = outage
        if outage.suspected_failure.is_a? Hop then 
            ip = outage.suspected_failure.ip
            # see if there is a revtr from that hop, at the time of the
            # outage.
            found = false
            $mysql_con.query("select * from cache_rtrs_archive where dest=inet_aton('#{ip}') and date>from_unixtime(#{outage.time.to_i-24*6*60})"+
                             " and date<from_unixtime(#{outage.time.to_i+24*60*60}) limit 1").each_hash{|row|
               found = print_revtr_pretty(row)
                
                             }
            if found then IRB.start end
        else
            puts "Suspected failure is: #{outage.suspected_failure} #{outage.suspected_failure.class}"
        end
    end
        

    log_count+=1
    if log_count%1000 == 0 then $stderr.puts filter_fail_counts.to_s
        $stderr.puts "Passed filter no dst tr: #{passed_filter_no_dst_tr}" 
        $stderr.puts "reverse path info: #{month2pathinfo2count.inspect}"
    end
    next


    confirmation_trace = nil
#    puts "#{outage.src} #{outage.dst} #{outage.time}"
    if not outage.nil? and not outage.file.split("_").length !=2 then next end
    date = outage.file.split("_")[2]
    month = date[4..5].to_i

#    if month < 8 then next end

    if month == 9 or month == 8 then 

    if outage.dst_tr.nil? or outage.dst_tr.length == 0 or outage.tr.nil? or outage.tr.length==0

        src2tr = get_nearest_traceroutes(outage, date)

        if src2tr.length==0 then next else 
            #        puts "Found some help!"
            #        puts src2tr.inspect
            src2tr.keys.each{|src|
                found_help+=src2tr[src].length 
                if $pl_host2site[src] == outage.src then 
                    #                puts "Found source to dest"
                    if outage.tr.nil? or outage.tr.length == 0 then 
                        if src2tr[src].include? :during then outage.tr = src2tr[src][:during]; used_help+=1 end
                    end
                    if outage.historical_tr.nil? or outage.historical_tr.length==0 then
                        if src2tr[src].include? :historic then outage.historical_tr = src2tr[src][:historic]; used_help+=1 end
                    end

                elsif  $pl_host2site[$pl_ip2host[outage.dst]] == $pl_host2site[src] then 
                    #                puts "Found dest to src" 
                    if outage.dst_tr.nil? or outage.dst_tr.length==0 then 
                        if src2tr[src].include? :during then outage.dst_tr= src2tr[src][:during]; used_help+=1 end                    
                        confirmation_trace = src2tr[src][:during]
                    end
                    if outage.historical_revtr.nil? or outage.historical_revtr.length == 0 then 
                        #                    if src2tr[src].include? :historic then outage.historical_revtr = src2tr[src][:historic]; used_help+=1 end
                        if confirmation_trace.nil? then confirmation_trace = src2tr[src][:historic] end
                    end
                end
            }
        end
    
        #    puts "Dst tr: " + outage.dst_tr.to_s#join("\n")#to_s
        #    puts "Dst spoofed: " + outage.dst_spoofed_tr.to_s#join("\n")#to_s
        #    puts "Tr: " + outage.tr.to_s#join("\n")#to_s
        #    puts "Spoofed tr:" + outage.spoofed_tr.to_s#join("\n")#.to_s
        #    #analyzer.identify_fault_single_outage(outage)
        #    puts "Suspected failure:" + outage.suspected_failures.to_s
    end
    end

    #    if month < 8 then puts date end
#    if month < 8 then passed_filters = outage.passed_filters 
#    else
    #    passed_filters = outage.passed_filters  
        results = analyzer.passes_filtering_heuristics?(outage.src, outage.dst, outage.tr, outage.spoofed_tr, 
                                                           outage.ping_responsive, outage.historical_tr, 
                                                           outage.historical_revtr, outage.direction, false, outage.file, true)
        passed_filters = results[0] 
        results[1].each{|key,bool| if bool then filter_fail_counts[key]+=1; break end}
#    end

    if passed_filters and outage.dataset == DataSets::ATTTargets then att_passed+=1 end
    next unless outage.symmetric
    total += 1
    next unless passed_filters #outage.passed_filters
    passed += 1

    if outage.dst_tr.valid?
        dst_tr_working += 1 
    end

    if outage.dst_spoofed_tr.valid?
        dst_spoofed_tr_working += 1
    end

     if passed_filters && (outage.dst_tr.valid? || outage.dst_spoofed_tr.valid?)
    cases_of_interest << outage.file 

    #puts outage.inspect
    puts "======"
    File.open("#{$OUTDIR}interesting/#{outage.file}-traces.txt", "w+"){|f|
    f.puts "File: #{outage.file}"
    puts "File: #{outage.file}"
    date = outage.file.split("_")[2]
    f.puts "Dst tr: \n" + outage.dst_tr.join("\n")#to_s
    f.puts "Dst spoofed: \n" + outage.dst_spoofed_tr.join("\n")#to_s
    f.puts "Tr: \n" + outage.tr.join("\n")#to_s
    f.puts "Spoofed tr: \n" + outage.spoofed_tr.join("\n")#.to_s
    f.puts "Historical tr:\n" + outage.historical_tr.join("\n")#.to_s
    f.puts "Historical revtr:\n" + outage.historical_revtr.join("\n")#.to_s
    f.puts "Confirmation:\n" + (confirmation_trace.nil? ? "" : confirmation_trace.join("\n"))
    analyzer.identify_fault_single_outage(outage)
    f.puts "Suspected failure:\n" + outage.suspected_failures.to_s   
    }
    File.open("#{$OUTDIR}interesting/#{outage.file}.bin", "wb+"){|f| f.write Marshal.dump(outage) }
    puts "===="
     elsif passed_filters
         passed_filter_no_dst_tr+=1
     end
    #    IRB.start

    # print the traceroutes?
    # Alternatively, print all (absolute paths to ) files with
    # puts "#{FailureIsolation::IsolationResults}/#{o.file}.bin"
    #
    # then run that list with ./finding_logs/irb_iterate_filesX.rb
    # to look at each outage interactively
end

puts "total: #{total}"
puts "passed: #{passed}"
puts "dst_tr_working: #{dst_tr_working} #{dst_tr_working*1.0/total}"
puts "dst_spoofed_tr_working: #{dst_spoofed_tr_working} #{dst_spoofed_tr_working*1.0/total}"
#puts "dst_tr_passed: #{dst_tr_passed} #{dst_tr_passed*1.0/passed}"
#puts "dst_spoofed_tr_passed: #{dst_spoofed_tr_passed} #{dst_spoofed_tr_passed*1.0/passed}"
puts "found help: #{found_help}"
puts "used help: #{used_help}"
puts "att passed:  #{att_passed}"
puts cases_of_interest
puts filter_fail_counts.inspect
