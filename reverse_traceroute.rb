#!/homes/network/revtr/ruby/bin/ruby
# if i get no rr responses, mark that destination as bad and don't probe more?
# if i learn RR reverse hops r1-r2-r3, it currently won't use r2-r3 if i reach
# r2 from something other than r1
# doesn't deal well if one ip in a cluster responds and another doesn't
# 	bc it assumes we will get same responses for one as another
require 'drb'
require 'sql'
require 'timeout'
require 'resolv'

#$LOG.output_stream = File.open("/homes/network/justine/colin_ips_out", "a")

class Adjacency < ActiveRecord::Base 
	set_table_name "adjacencies"
	def <=> (b)
		self.cnt <=> b.cnt
	end
end

class AdjacencyToDest < ActiveRecord::Base 
	set_table_name "adjacencies_to_dest"
	def <=> (b)
		self.cnt <=> b.cnt
	end
end

class MySQLTimeout < Timeout::Error
end
def getAdjacenciesForIPtoSrc( ip, src, settings={} )
	timeout_val = ( settings.include?(:timeout) ? settings[:timeout] : 60 )
	maxnum = ( settings.include?(:maxnum) ? settings[:maxnum] : 30 )
	maxalert = ( settings.include?(:maxalert) ? settings[:maxalert] : EMAIL )
	retry_command = ( settings.include?(:retry) ? settings[:retry] : true )
	$LOG.puts("Looking for adjacents for #{ip} to dst #{src}")
	ip_int=Inet::aton(ip)
	dest24=Inet::aton(src) >> 8
	adjacents = []
	begin
		ip1s,ip2s,adjacencies_to_dest=nil
		Timeout::timeout(timeout_val, MySQLTimeout.new("MySQLTimeout after #{timeout_val} checking for adjacents for #{ip} to dst #{src}")){
			ip1s=Adjacency.find_all_by_ip1(ip_int)
			ip2s=Adjacency.find_all_by_ip2(ip_int)
			adjacencies_to_dest = AdjacencyToDest.find_all_by_address_and_dest24(ip_int, dest24).sort!.collect{|x| Inet::ntoa(x.adjacent)}.reverse
		}
		adjacencies=(ip1s + ip2s).sort.collect{|x| x.ip1==ip_int ? Inet::ntoa(x.ip2) : Inet::ntoa(x.ip1) }.reverse
		adjacents = adjacencies_to_dest + ( adjacencies - adjacencies_to_dest ) - [ip]
		$LOG.puts("Found #{adjacents.length} adjacents for #{ip} to dst #{src}")
	rescue
		if retry_command
			$LOG.puts("Exception #{$!.class} #{$!.to_s} trying to get adjacents.  Retrying")
			retry_command=false
			sleep 2
			retry
		else
			if settings.include?(:backtrace)
				$!.set_backtrace($!.backtrace + settings[:backtrace])
			end
			$LOG.puts(["Exception #{$!.class} trying to get adjacents from MySQL", "EXCEPTION #{$!.class}! Unable to get adjacents for #{ip} to dst #{src}\n" + $!.to_s + "\n" + $!.backtrace.join("\n")], [$SQL_CONNECT_ERROR,maxalert].max)
		end
	end
	return adjacents[0...maxnum]
end

class ReversePath

	# can redefine <=> to prioritize paths to explore
	#@path is the current path so far, an array of RevSegments
	def initialize(src,dst,path=nil)
		@src=src
		@dst=dst
		if path.nil?
			@path=[DstRevSegment.new([dst],src,dst)]
		else
			@path=path
		end
	end

	def initialize_copy(source)
		@path=source.path.dup
	end

	attr_reader :src, :dst, :path

	def hops
		@path.collect{|seg| seg.hops}.flatten
	end

	def length
		@path.inject(0){|sum,seg| sum + seg.length}
	end

	def lastHop
		@path.at(-1).lastHop
	end

	def lastSeg
		@path.at(-1)
	end

	def pop
		@path.pop
	end

	def reaches?
		@path.at(-1).reaches?
	end

	def symmetric_assumptions
		@path.collect{|x| x.symmetric_assumptions }.inject(0){ |s,v| s += v } 
	end
	# hops_to_ignore are those we should skip, such as ones known to be

	def to_s(verbose=false)
		if verbose
			"RevPath_D#{@dst}_S#{@src}_#{@path.join(",")}"
		else
			"RevPath_D#{@dst}_S#{@src}_#{self.hops.join(" ")}"
		end
	end

	def << (seg)
		@path << seg
		self
	end
	
end

class ReverseTraceroute
	ReverseTraceroute::RATELIMIT=3
	# @paths is a stack of ReversePaths
	# @paths.at(-1) is the current one
	# it functions like a stack
	# @deadend is a hash ip -> bool of paths (stored as lasthop) we know don't work and
	# shouldn't be tried again
	#	@rrhop2ratelimit is from cluster to max number of probes to send to it
	#	in a batch
	#	@rrhop2vpsleft is from cluster to the VPs that haven't probed it yet,
	#	in prioritized order
	# @tshop2ratelimit is max number of adjacents to probe for at once.
	# @tshop2adjsleft is from cluster to the set of adjacents to try, in
	# prioritized order.  [] means we've tried them all.  if it is missing the
	# key, that means we still need to initialize it
#	# @rtts is a map from hop (string IP address) to a list of string RTTs
#	# measured to that hop (if any have been set).  ["*"] for any hops that
#	# we do not have measurements for, or nil if none have been set
	def initialize(src,dst)
		@src=src
		@dst=dst
		@paths=[ReversePath.new(src,dst)]
		@deadend=Hash.new(false)
		@rrhop2ratelimit=Hash.new(ReverseTraceroute::RATELIMIT)
		@rrhop2vpsleft=Hash.new
		@tshop2ratelimit=Hash.new(1)
		@tshop2adjsleft=Hash.new
#		@rtts=nil
	end
	
	def symmetric_assumptions
		@paths.at(-1).symmetric_assumptions
	end

	def deadends
		return @deadend.keys
	end

	# todo:
	# put src/prober in segments?
	#
	# hop -> TS adjacents tried
	# or, better, map from hop to (# to try at once, [left to try])
	# first time through, initialize these values
	# after, just try next bunch
	# if empty, fail
	# can subclass ReverseTraceroute based on how to assign these values
	#
	# option to set whether to assume last hop is symmetric
	# if we don't reach original dst, return error

	attr_reader :src, :dst #, :rtts

#	def add_rtts(pings)
#	end

	# for now, we just use stupid generic initialization
	# can override it be extending the class
	def initialize_rr_vps(cls)
		$LOG.puts "Initializing RR VPs individually for spoofers for #{cls}"
		@rrhop2ratelimit[cls]=ReverseTraceroute::RATELIMIT
		site2spoofer=choose_one_spoofer_per_site
		sites_for_target=nil
		begin
			ProbeController::issue_to_vp_server{|server|
				sites_for_target=server.get_sites_for_ip(cls)
				if (not sites_for_target.nil?) and sites_for_target.length>0
					$LOG.puts "Found #{sites_for_target.length} spoofers for #{self.src} #{cls}"
				end
			}
		rescue DRb::DRbConnError
			$LOG.puts "EXCEPTION! Server refused connection trying to get nearby VPs: " + $!.to_s, $DRB_CONNECT_ERROR
		end
		spoofers_for_target=[]
		if sites_for_target.nil? 
			spoofers_for_target=site2spoofer.values.sort_by {rand}
		else
			spoofers_for_target=(sites_for_target & site2spoofer.keys).collect{|site| site2spoofer[site]}
		end
		@rrhop2vpsleft[cls]=[:non_spoofed] + (spoofers_for_target - [@src])
	end	

	# like initialize_rr_vps, but do it in a batch, including requesting from
	# the vp server in a batch
	# will initialize them all for the last hop
	def ReverseTraceroute.batch_initialize_rr_vps(reverse_traceroutes)
		ips_to_init=Hash.new{|h,k| h[k] = [] }
		reverse_traceroutes.each{|revtr|
			# iterate through all hops in the last segment
			revtr.curr_path.path.at(-1).hops.each{|hop|
				# we either use destination or cluster, depending on how flag is set
				cls=$rr_vps_by_cluster ? $ip2cluster[hop] : hop
				if hop=="0.0.0.0"
					revtr.set_rr_vps_for_hop(cls,[])
					next
				end
				if not revtr.rr_vps_initialized_for_hop?(cls)
					ips_to_init[cls] << revtr
				end
			}
		}
		if not ips_to_init.empty?
			$LOG.puts "Initializing RR VPs in a batch for #{ips_to_init.length}"
			site2spoofer=choose_one_spoofer_per_site
			sites_for_targets=Hash.new
			begin
				ProbeController::issue_to_vp_server{|server|
					sites_for_targets=server.get_sites_for_ips(ips_to_init.keys)
				}
			rescue DRb::DRbConnError
				$LOG.puts "EXCEPTION! Server refused connection trying to get nearby VPs: " + $!.to_s, $DRB_CONNECT_ERROR
			end

			ips_to_init.each_pair{|ip,revtrs_for_ip|
				spoofers_for_target=[]
				if sites_for_targets.has_key?(ip) and (not sites_for_targets[ip].nil?)
					spoofers_for_target=(sites_for_targets[ip] & site2spoofer.keys).collect{|site| site2spoofer[site]}
					$LOG.puts "Found #{spoofers_for_target.length} spoofers of #{sites_for_targets[ip].length} for #{ip}: #{spoofers_for_target.join(" ")}"
				else
					spoofers_for_target=site2spoofer.values.sort_by {rand}
					$LOG.puts "Resorting to all #{spoofers_for_target.length} spoofers for #{ip}"
				end
				revtrs_for_ip.each{|revtr|
					revtr.set_rr_vps_for_hop(ip,[:non_spoofed] + (spoofers_for_target - [revtr.src]))
				}
			}
		end
	end

	def rr_vps_initialized_for_hop?(hop)
		@rrhop2vpsleft.has_key?(hop)
	end

	def set_rr_vps_for_hop(hop,vps)
		@rrhop2vpsleft[hop]=vps
	end

	# returns the next set to probe from, plus the next destination to probe
	# nil means none left, already probed from everywhere
	# the first time, initialize the set of VPs
	# if any exist that have already probed the dst but havent been used in
	# this reverse traceroute, return them
	# otherswise, return [:non_spoofed] first
	# then sets of spoofing VPs on subsequent calls
	def get_rr_vps(dst)
		# we either use destination or cluster, depending on how flag is set
		if not $BATCH_INIT_RR_VPS
			self.curr_path.path.at(-1).hops.each{|hop|
				cls=$rr_vps_by_cluster ? $ip2cluster[hop] : hop
				if not @rrhop2vpsleft.has_key?(cls)
					self.initialize_rr_vps(cls)
				end
			}
		end
		# CASES:
		seg_hops=self.curr_path.path.at(-1).hops.clone
		target=nil
		cls=nil
		found_vps=false
		while (not found_vps) and (not seg_hops.empty?)
			target=seg_hops.pop
			cls=$rr_vps_by_cluster ? $ip2cluster[target] : target
		# 0. destination seems to be unresponsive
			if  $rrs_src2dst2vp2revhops[@src][cls].length >= $MAX_UNRESPONSIVE and $rrs_src2dst2vp2revhops[@src][cls].values.compact.length==0
				$LOG.puts "Current hop #{target}/#{cls} seems to be unresponsive for #{@src} #{@dst}"
				next
			end
		# 1. no VPs left, return nil
			if @rrhop2vpsleft[cls].empty?
				next
			end
			found_vps=true
		end
		if not found_vps
			return nil, nil
		end
		$LOG.puts "#{@src} #{@dst} #{target} #{@rrhop2vpsleft[cls].length} RR VPs left to try"
	
		# 2. probes to this dst that were already issued for other reverse
		# traceroutes, but not in this
		# reverse traceroute
		used_vps= $rrs_src2dst2vp2revhops[@src][cls].keys & @rrhop2vpsleft[cls]
		@rrhop2vpsleft[cls] = @rrhop2vpsleft[cls] - used_vps
		used_vps.delete_if{|vp|
			$rrs_src2dst2vp2revhops[@src][cls][vp].nil? or $rrs_src2dst2vp2revhops[@src][cls][vp].empty? 
		}
		if used_vps.length > 0
			return used_vps,target
		end	

		# 3. send non-spoofed version if it is in the next batch
		if @rrhop2vpsleft[cls][0...([@rrhop2ratelimit[cls],@rrhop2vpsleft[cls].length].min)].include?(:non_spoofed)
			@rrhop2vpsleft[cls].delete(:non_spoofed)
			return [:non_spoofed],target
		end

		# 4. use unused spoofing VPs
		# if the current last hop was discovered with spoofing, and it
		# hasn't been used yet, use it
		if (not @paths.empty?) and @paths.at(-1).path.at(-1).is_a?(SpoofRRRevSegment) and not $rrs_src2dst2vp2revhops[@src][cls].keys.include?(@paths.at(-1).path.at(-1).spoofer)
			$LOG.puts "FOUND RECENT SPOOFER TO USE #{@paths.at(-1).path.at(-1).spoofer}"	
			@rrhop2vpsleft[cls].delete(@paths.at(-1).path.at(-1).spoofer)
			vps = [@paths.at(-1).path.at(-1).spoofer] + @rrhop2vpsleft[cls][0...([@rrhop2ratelimit[cls]-1,@rrhop2vpsleft[cls].length].min)]
			@rrhop2vpsleft[cls][0...([@rrhop2ratelimit[cls]-1,@rrhop2vpsleft[cls].length].min)]=[]
			return vps,target
		end
		vps = @rrhop2vpsleft[cls][0...([@rrhop2ratelimit[cls],@rrhop2vpsleft[cls].length].min)]
		@rrhop2vpsleft[cls][0...([@rrhop2ratelimit[cls],@rrhop2vpsleft[cls].length].min)]=[]
		return vps,target
	end

	# for now we're just ignoring the src dst and choosing randomly
	# this is static and the source is passed in, rather than being instance
	# and you get the source from @src, bc we invoke it based on probes where
	# we have the src/dst, but not the revtr
	def ReverseTraceroute::get_timestamp_spoofers(src, dst)
		site2spoofer=choose_one_spoofer_per_site
		ts_sites=$ts_spoofer_sites.sort_by{rand} - [$pl_host2site[src]]
		spoofers=[]
		i=0
		while i < ts_sites.length and spoofers.length < 5
			if site2spoofer.has_key?(ts_sites.at(i))
				spoofers << site2spoofer[ts_sites.at(i)]
			end
			i += 1
		end
		return spoofers
	end

	def initialize_ts_adjacents(cls)
		#@tshop2ratelimit[cls]=1 already defaults to 1 
		@tshop2adjsleft[cls]=[]
		timeout=10
		begin
			Timeout::timeout(timeout) do
				@tshop2adjsleft[cls]=getAdjacenciesForIPtoSrc( cls, self.src )
				@tshop2adjsleft[cls].delete_if{|x| cls==$ip2cluster[x]}
				if @tshop2adjsleft[cls].length>0
					$LOG.puts "Adjacents for #{self.src} #{cls} are #{@tshop2adjsleft[cls].join(" ")}"
				end
			end
		rescue Timeout::Error
			$LOG.puts(["Timeout getting adjacents", "EXCEPTION Unexpected Timeout::Error after #{timeout} trying to get adjacents " +$!.to_s], $TIMEOUT_ERROR)
		end
# 			ProbeController::issue_to_adjacency_server{|server|
# 				@tshop2adjsleft[cls]=server.getAdjacenciesForIPtoSrc( cls, self.src )
# 				@tshop2adjsleft[cls].delete_if{|x| cls==$ip2cluster[x]}
# 				if @tshop2adjsleft[cls].length>0
# 					$LOG.puts "Adjacents for #{self.src} #{cls} are #{@tshop2adjsleft[cls].join(" ")}"
# 				end
# 			}
# 		rescue DRb::DRbConnError
# 			$LOG.puts "EXCEPTION! Server refused connection trying to get adjacents: " + $!.to_s, $DRB_CONNECT_ERROR
# 		end
	end	

	# get the set of adjacents to try for a hop
	# for revtr:s,d,r, the set of R' left to consider, or if there are none
	# will return the number that we want to probe at a time
	def get_ts_adjacents(hop)
		cls=$ts_adjs_by_cluster ? $ip2cluster[hop] : hop
		if not @tshop2adjsleft.has_key?(cls)
			self.initialize_ts_adjacents(cls)
		end
		$LOG.puts "#{self.src} #{self.dst} #{self.lastHop} #{@tshop2adjsleft[cls].length} TS adjacents left to try"

		# CASES:
		# 1. no adjacents left, return nil
		if @tshop2adjsleft[cls].empty?
			return nil
		end
		# CAN EVENTUALLY MOVE TO REUSSING PROBES TO THIS DST FROM ANOTHER
		# REVTR, BUT NOT FOR NOW
		# 2. For now, we just take the next batch and send them
		adjacents = @tshop2adjsleft[cls][0...([@tshop2ratelimit[cls],@tshop2adjsleft[cls].length].min)]	
		@tshop2adjsleft[cls][0...([@tshop2ratelimit[cls],@tshop2adjsleft[cls].length].min)]=[]
		return adjacents
	end

	def curr_path
		@paths.at(-1)
	end

	def hops
		if @paths.length==0
			return []
		end
		@paths.at(-1).hops
	end

	def lastHop
		@paths.at(-1).lastHop
	end

	# assumes that any path reaches if and only if the last one reaches
	def reaches?
		@paths.at(-1).reaches?
	end

	# returns whether we have any options left to explore
	def failed?(backoff_endhost=false)
		@paths.length==0 or (backoff_endhost and @paths.length==1 and @paths.at(0).path.length==1 and @paths.at(0).path.at(0).class==DstRevSegment) 
	end

	# Need a different function because a TR segment might intersect at an IP back 
	# up the TR chain, want to delete anything that has been added in along the way.
	def add_background_tr_segment(tr_segment)
		matched = false
		found = nil

		# iterate through the paths, trying to find one that contains
		# intersection point
		# chunk is a ReversePath
		@paths.each{|chunk|

			# index is the hop # in the path of the intersection
			# note that the tr_segment.segment / .hops contains the
			# intersection point, which is not how RevSegments normally store
			# things.  normally, .hop is the intersection point, and .segment
			# / .hops starts after that.  emailed justine to resolve this
			if((index = chunk.hops.index(tr_segment.hops[0])) != nil) then
				$LOG.puts "INTERSECTED #{tr_segment.hops[0]} in #{chunk.inspect}"
				chunk = chunk.clone
				found = chunk
				
				# Iterate through all the segments until you find the 
				# hop where they intersect. After reaching the hop where 
				# they intersect, delete any subsequent hops within the same segment.
				# Then delete any segments after.
				k = 0 #Which IP hop we're at
				size = chunk.path.size
				j = 0 #Which segment we're at

				# while we still have hops to delete
				while(chunk.hops.size - 1 > index) 

					# get the current segment
					seg = chunk.path[j]
					# if we're past the intersection point then delete the whole segment
					if(k > index) then
						chunk.path.delete(seg)
					# if the intersection point is in this segment
					# then delete the tail of the segment	
					elsif(k + seg.hops.size - 1 > index) 
						l = seg.hops.index(tr_segment.hops[0]) + 1
						while(k + seg.hops.size - 1 > index) 
							seg.hops.delete_at(l)
						end
					# otherwise, move to the next segment
					else
						j+=1 
						k+= seg.hops.size
					end
				end
			break
			end
		}
		if found.nil? then
				$LOG.puts self.inspect
				$LOG.puts tr_segment.inspect
				raise NoIntersectionException "Tried to add traceroute to Reverse Traceroute that didn't share an IP... what happened?!"
		else
			@paths << found
		end
		# Now that the traceroute is cleaned up, add the new segment
		# this sequence slightly breaks how add_segment normally works
		# here, we append a cloned path (with any hops past the intersection
		# trimmed).  then, we call add_segment.  add_segment clones the last
		# path, then adds the segment to it.  so, we end up with an extra copy
		# of found, that might have some hops trimmed off it.  not the end of
		# the world, but something to be aware of.
		success = add_segments([tr_segment])
		if !success then
			@paths.delete(found)
		end
		return success
	end

	# returns a bool of whether any were added
	# might not be added if they are deadends
	# or if all hops would cause loops
	def add_segments(segments)
		# sort them based on whether they reached
		# or how long the path is
		added=false
		sorted=segments.sort	
		basePath=self.curr_path.clone
		sorted.each{|segment|
			#if not (@deadend[$ip2cluster[segment.lastHop]])
			if not (@deadend[segment.lastHop])
				# add loop removal here
				segment.remove_hops(basePath.hops)
				if segment.length==0
					$LOG.puts "Skipping loop-causing segment #{segment.to_s(true)}"
					next
				end
				added=true
				@paths << ( basePath.clone << segment )
			end
		}
		added
	end

	# add a new path, equal to the current one but with the last segment
	# replaced by the new one
	# returns a bool of whether it was added
	# might not be added if it is a deadend
	def add_and_replace_segment(segment)
		#if @deadend[$ip2cluster[segment.lastHop]]
		if @deadend[segment.lastHop]
			false
		else
			base_path=self.curr_path.clone
			base_path.pop
			@paths << ( base_path << segment )
			true
		end
	end
	# mark the curr path as failed
	def fail_curr_path
		#@deadend[$ip2cluster[self.lastHop]] = true
		@deadend[self.lastHop] = true
		# keep popping until we find something that is either on a path we
		# are assuming symmetric (we know it started at src so goes the
		# whole way) or is not known to be a deadend
		#while (not self.failed?) and (@deadend[$ip2cluster[self.lastHop]] and self.curr_path.lastSeg.class!=DstSymRevSegment)
		while (not self.failed?) and (@deadend[self.lastHop] and self.curr_path.lastSeg.class!=DstSymRevSegment)
			$LOG.puts "Failing path: #{@paths.pop.to_s(true)}"
		end	
	end

	def to_s(verbose=false)
		if verbose
			path_s = @paths.collect{|path| 
				"[" + path.to_s(true) + "]"}.join("\n")
				
			"RevTR_D#{@dst}_S#{@src}_{#{path_s}}"
		else
			"RevTR_D#{@dst}_S#{@src}_[#{self.hops.join(" ")}]"
		end
	end

    # Build an output that looks vaguely like a traceroute
	# Might look weird if the revtr is not complete
	# pings is pings[[src,dstip]] << rtt.to_f
	def get_revtr_string(pings={})
		result = "reverse traceroute from #{Resolv.getname(self.hops.first) rescue ""} (#{self.hops.first}) back to #{Resolv.getname(self.hops.last) rescue ""} (#{self.hops.last})\n"
		hops_seen = Hash.new(false)
		$LOG.puts self.curr_path.to_s(true)

		# For every hop, add a line
		i = 0
		self.curr_path.path.each { |segment|
			first = true
			symbol = ""
			case segment
				when DstSymRevSegment then symbol = "sym"
				when DstRevSegment then symbol = "dst"
				when TRtoSrcRevSegment then symbol = "tr"
				when SpoofRRRevSegment then symbol = "rr"
				when RRRevSegment then symbol = "rr"
				when SpoofTSAdjRevSegmentTSZeroDoubleStamp then symbol = "ts"
				when SpoofTSAdjRevSegmentTSZero then symbol = "ts"
				when SpoofTSAdjRevSegment then symbol = "ts"
				when TSAdjRevSegment then symbol = "ts"
			end
			segment.hops.each { |hop|

				# Array of ping values for this hop
				rtt = pings[[self.src, hop]]
				
				# We don't want to go in a big loop
				if $prune_loops
					next if hops_seen[hop]
					hops_seen[hop]=true
				end
				
				# Get the hostname
				presentation = Resolv.getname(hop) rescue ""     
				
				# Get the technique
				technique = first ? symbol : "-" + symbol
				first = false
		
				# Add the line
				if hop == "0.0.0.0" or hop == "\*"
					result += "#{i.to_s.rjust(2)}  * * *".ljust(120) + " #{technique}\n"
				elsif rtt == []
					result += "#{i.to_s.rjust(2)}  #{presentation} (#{hop}) *".ljust(120) + "  #{technique}\n"
				else
					rtt = rtt[0..2] if rtt.length > 3
					result += "#{i.to_s.rjust(2)}  #{presentation} (#{hop}) #{rtt.join(" ms ")} ms".ljust(120) + " #{technique}\n"
				end

				# Increment the counter
				i += 1
			}  
		}
		
		return result
	 
	end

end

$spoofing_sites=Hash.new
$spoofing_hosts=Hash.new
File.open($ALL_SPOOFERS,"r"){|file|
	file.each_line{|line|
		spoofer=line.chomp("\n")
		site=$pl_host2site[spoofer]
		$spoofing_sites[site]=true
		$spoofing_hosts[spoofer]=true
	}
}
# returns a hash from site to spoofer hostname
def choose_one_spoofer_per_site

	begin
		ProbeController::issue_to_controller{|controller|
			if $touch_spoofers_when_choosing
				# poke all the potential spoofers to make sure they really are active
				controller.issue_command_on_hosts($spoofing_hosts, { :retry => true, :backtrace => caller} ){|h,p| h.system("echo touch")}
			end
			all_vps=controller.hosts.sort_by{rand}
			$LOG.puts "Total VPs: #{all_vps.length}"
			$LOG.puts "Total spoofers: #{$spoofing_hosts.length} at #{$spoofing_sites.length} sites"

			site2vp=Hash.new
			all_vps.each{|v|
				site2vp[ $pl_host2site[v] ] = v
			}
			up_spoofers = (all_vps & $spoofing_hosts.keys).sort_by {rand}
			site2spoofer=Hash.new
			up_spoofers.each{|s|
				site2spoofer[ $pl_host2site[s] ] =s
			}
			$LOG.puts "Total up spoofers: #{up_spoofers.length} at #{site2spoofer.length} sites"

			# find sites for which we found a spoofer, but it isn't up
			# and see if we have another up vp at that site
			(($spoofing_sites.keys - site2spoofer.keys) & (site2vp.keys)).each{|s|
				$LOG.puts "Adding additional host at spoofing site #{site2vp[s]}"
				site2spoofer[s] = site2vp[s]
			}
			$LOG.puts "Final total spoofers to use: 1 each at #{site2spoofer.length} sites"
			return site2spoofer
		}
	rescue DRb::DRbConnError
		$LOG.puts "EXCEPTION! Controller refused connection trying to choose spoofers, failing: " + $!.to_s, $DRB_CONNECT_ERROR
		raise
	end
end


# traceroutes we've issued
# nil for the path means that we issued it but didn't get a response
# not guaranteed to have reached
# dst is a cluster
$trs_src2dst2path = Hash.new { |hash, key|  hash[key] = Hash.new}

def issue_traceroutes( pairs, dirname, delete_unresponsive=false)
	`mkdir -p #{dirname}`
	trs_to_issue=Hash.new { |hash, key| hash[key] = [] } 
	pairs.each{|pair|
		$trs_src2dst2path[pair.at(0)][$ip2cluster[pair.at(1)]]=nil
		trs_to_issue[$pl_ip2host[pair.at(0)]] << pair.at(1)

	}
	$LOG.puts "Issuing traceroutes: " + `date +%Y.%m%d.%H%M.%S`.chomp("\n") + " " + pairs.length.to_s
	$probe_counts["tr"] += pairs.length
	results=[]
	if $issue_probes
		begin
			ProbeController::issue_to_controller{|controller|
				results,unsuccessful_hosts,privates,blacklisted=controller.traceroute(trs_to_issue, { :retry => true, :backtrace => caller} )
			}
		rescue DRb::DRbConnError
			$LOG.puts "EXCEPTION! Controller refused connection trying to issue traceroutes: " + $!.to_s, $DRB_CONNECT_ERROR
		end

	end
	results.each{|p|
		probes = p.at(0)
		src = p.at(1)
		$LOG.puts "Traceroutes for #{src}"
		if $log_probes
			`mkdir -p #{dirname}`
			f=nil
			begin
				f = File.new("#{dirname}/trace.out." + src,  "wb")
				f.write(probes)
			ensure
				  f.close unless f.nil?
			end
		end
		trs=[]
		begin
			trs=convert_binary_traceroutes(probes)
		rescue TruncatedTraceFileException => excep
			$LOG.puts "Error in TR file #{dirname}/trace.out.#{src}: " + $!.to_s,TRUNCATED_FILE_ERROR
			$LOG.puts $!.backtrace.join("\n")
			trs=excep.partial_results
		end
		trs.each{|tr|
			dst=tr.at(0)
			hops=tr.at(1)
			if delete_unresponsive
				hops.delete("0.0.0.0")
			end
			cls=$ip2cluster[dst]
			$trs_src2dst2path[src][cls] = hops
		}
	}
	# 	targfn = dirname + "/targs.txt"
	# 	if $old_tools
	# 		File.open( targfn, File::CREAT|File::TRUNC|File::WRONLY|File::APPEND) {|trf|
	# 			pairs.each{|probe|
	# 				trf.puts probe.join(" ")
	# 			}
	# 		}
	# 	else
	# 		trs_to_issue=Hash.new { |hash, key| hash[key] = [] } 
	# 		pairs.each{|pair|
	# 			trs_to_issue[pair.at(0)] << pair.at(1)
	# 
	# 		}
	# 		File.open( targfn, File::CREAT|File::TRUNC|File::WRONLY|File::APPEND) {|trf|
	# 			trs_to_issue.each_pair{|s,targs|
	# 				trf.puts "{#{s}} #{targs.join(" ")}"
	# 			}
	# 		}
	# 
	# 	end
	# 	if $issue_probes
	# 		`#{$TRSCRIPT} #{targfn} #{dirname} #{$PC_IP} #{$PC_PORT}`
	# 	end
	# 	$LOG.puts "Issuing traceroutes: " + `date +%Y.%m%d.%H%M.%S`.chomp("\n") + " " + `wc -l #{targfn}` 
	# 	pairs.each{|p|
	# 		$trs_src2dst2path[p.at(0)][$ip2cluster[p.at(1)]]=nil
	# 	}
	# 	`find -L #{dirname} -name 'trace.out.\*'`.each{|trfn|
	# 		`#{$READTR} #{trfn.chomp("\n")} 0`.each{|tr|
	# 			info = tr.chomp("\n").split(" ")
	# 			src = info.at(1)
	# 			dst = info.at(2)
	# 			hops = info[4..-1]
	# 			if delete_unresponsive
	# 				hops.delete("0.0.0.0")
	# 			end
	# 			cls=$ip2cluster[dst]
	# 			$trs_src2dst2path[src][cls] = hops
	# 		}
	# 	}
end

# record routes we've issued, spoofed and non-spoofed
# nil for the path means that we issued it but didn't get a response
# [] means we got a response, but no reverse hops
# otherwise, this will store the reverse hops, not including the destination
# cluster
# dst had previously been a cluster, now working out whether it should be the
# Ip or the cluster
# VP is  :non_spoofed for nonspoofed
$rrs_src2dst2vp2revhops = Hash.new { |hash, key|  hash[key] = Hash.new { |in_hash, in_key|  in_hash[in_key] = Hash.new}}
# rrs_to_issue=[[src,dst] pairs] 
def issue_recordroutes(pairs,dirname, delete_unresponsive=true)
					# 	`mkdir -p #{dirname}`
					# 	targfn = dirname + "/targs.txt"
					# 	if $old_tools
					# 		File.open( targfn, File::CREAT|File::TRUNC|File::WRONLY|File::APPEND) {|rrf|
					# 			pairs.each{|probe|
					# 				rrf.puts probe.join(" ")
					# 			}
					# 		}
					# 	else
					# 		rrs_to_issue=Hash.new { |hash, key| hash[key] = [] } 
					# 		pairs.each{|pair|
					# 			puts pair.at(0) + ">" + pair.at(1)
					# 			rrs_to_issue[pair.at(0)] << pair.at(1)
					# 
					# 		}
					# 		File.open( targfn, File::CREAT|File::TRUNC|File::WRONLY|File::APPEND) {|rrf|
					# 			rrs_to_issue.each_pair{|s,targs|
					# 				rrf.puts "{#{s}} #{targs.join(" ")}"
					# 			}
					# 		}
					# 
					# 	end
					#	$LOG.puts "Issuing recordroutes: " + `date +%Y.%m%d.%H%M.%S`.chomp("\n") + " " + `wc -l #{targfn}` 
					# 	`find -L #{dirname} -name 'rrping.out.\*'`.each{|rrfn|
					# 		`#{$READRR} #{rrfn.chomp("\n")}`.each{|rr|
					# 			info = rr.chomp("\n").split(" ")
					# 			src = info.at(0)
					# 			dst = info.at(1)
					# 			cls=$ip2cluster[dst]
					# 			if delete_unresponsive
					# 				info.delete("0.0.0.0")
					# 			end
					# 			if info.length>3 and info[3..-1].uniq.length>1
					# 				hops = info[3..-1]
					# 			end
					# 			$rrs_src2dst2vp2revhops[src][cls][:non_spoofed]=process_rr(src,dst,hops)
					# 		}
					# 	}
	probes_to_issue=Hash.new{|h,source| h[source]=[]}
	pairs.each{|p|
		cls=$rr_vps_by_cluster ? $ip2cluster[p.at(1)] : p.at(1)
		$rrs_src2dst2vp2revhops[p.at(0)][cls][:non_spoofed]=nil
		probes_to_issue[$pl_ip2host[p.at(0)]] << p.at(1)
	}
	$probe_counts["rr"] += pairs.length
	$LOG.puts "Issuing recordroutes: " + `date +%Y.%m%d.%H%M.%S`.chomp("\n") + " " + pairs.length.to_s
	results=[]
	if $issue_probes
		#		`#{$RRSCRIPT} #{targfn} #{dirname} #{$PC_IP} #{$PC_PORT}`
		begin
			ProbeController::issue_to_controller{|controller|
				results,unsuccessful_hosts,privates,blacklisted=controller.rr(probes_to_issue, { :retry => true, :backtrace => caller} )
			}
		rescue DRb::DRbConnError
			$LOG.puts "EXCEPTION! Controller refused connection to issue rr: " + $!.to_s, $DRB_CONNECT_ERROR
		end
	end
	results.each{|p|
		probes = p.at(0)
		src = p.at(1)
		rrs=[]
		if $log_probes
			`mkdir -p #{dirname}`
			f=nil
			begin
				f = File.new("#{dirname}/rrping.out." + src,  "wb")
				f.write(probes)
			ensure
				  f.close unless f.nil?
			end
		end

		begin
			rrs=convert_binary_recordroutes(probes)
		rescue TruncatedTraceFileException => excep
			$LOG.puts "Error in RR file #{dirname}/rrping.out.#{src}: " + $!.to_s, TRUNCATED_FILE_ERROR
			$LOG.puts $!.backtrace.join("\n")
			rrs=excep.partial_results
		end
		rrs.each{|r|
			dst=r.at(0)
			hops=r.at(1)
			if delete_unresponsive
				hops.delete("0.0.0.0")
			end
			cls=$rr_vps_by_cluster ? $ip2cluster[dst] : dst
			$rrs_src2dst2vp2revhops[src][cls][:non_spoofed]=process_rr(src,dst,hops)
		}
	}
	return results
end

def issue_spoofed_recordroutes(receiver2spoofer2targets,dirname, delete_unresponsive=true)
	receiver2spoofer2targets.each_pair{|receiver,spoofer2targets|
		spoofer2targets.each_pair{|spoofer,targets|
			$probe_counts["spoof-rr"] += targets.length
			targets.each{|targ|
				$rrs_src2dst2vp2revhops[receiver][$rr_vps_by_cluster ? $ip2cluster[targ] : targ][spoofer]=nil
			}
		}
	}
	$LOG.puts "Issuing spoofed recordroutes: " + `date +%Y.%m%d.%H%M.%S`.chomp("\n") 
	results=[]
	if $issue_probes
		#		`#{$RRSCRIPT} #{targfn} #{dirname} #{$PC_IP} #{$PC_PORT}`
		begin
			ProbeController::issue_to_controller{|controller|
				$LOG.puts("Issuing to controller with : #{receiver2spoofer2targets.inspect}")
				results,unsuccessful_receivers,privates,blacklisted=controller.spoof_rr(receiver2spoofer2targets, { :retry => true, :parallel_receivers => :all, :backtrace => caller})
			}
		rescue DRb::DRbConnError
			$LOG.puts "EXCEPTION! Controller refused connection trying to spoof rr: " + $!.to_s, $DRB_CONNECT_ERROR
		end
	end
	results.each{|p|
		probes = p.at(0).at(0)
		spoofers_for_probes = p.at(0).at(1)
		src = p.at(1)
		$LOG.puts "#{src} received #{spoofers_for_probes.length} total responses from #{spoofers_for_probes.collect{|x| $pl_ip2host[x]}.join(" ")}"
		rrs=[]
		if $log_probes
			`mkdir -p #{dirname}`
			# TODO: not logging spoofers
			f=nil
			begin
				f = File.new("#{dirname}/spoof_rrping.out." + src,  "wb")
				f.write(probes)
			ensure
				  f.close unless f.nil?
			end
		end

		begin
			rrs=convert_binary_recordroutes(probes)
		rescue TruncatedTraceFileException => excep
			$LOG.puts "Error in RR file #{dirname}/rrping.out.#{src}: " + $!.to_s, TRUNCATED_FILE_ERROR
			$LOG.puts $!.backtrace.join("\n")
			rrs=excep.partial_results
		end
		if rrs.length != spoofers_for_probes.length
			$LOG.puts "Mismatch between RR length and spoofer list length: #{rrs.length} vs #{spoofers_for_probes.length}"

		end
		rrs.each_index{|rrs_i|
			r=rrs.at(rrs_i)
			spoofer_for_r=spoofers_for_probes.at(rrs_i)
			dst=r.at(0)
			hops=r.at(1)
			if delete_unresponsive
				hops.delete("0.0.0.0")
			end
			$rrs_src2dst2vp2revhops[src][$rr_vps_by_cluster ? $ip2cluster[dst] : dst][$pl_ip2host[spoofer_for_r]]=process_rr(src,dst,hops)
		}
	}
	return results
end
# given a src, dst, and RR hops (with 0.0.0.0 removed, but otherwise complete
# process it, returning reverse hops or [] if none
def process_rr(src,dst,hops,remove_loops=true)			
	if hops.nil?
		return []
	end
	dstcls = $ip2cluster[dst]
	if $ip2cluster[hops.at(-1)]==dstcls
		return []
	end
	i=hops.length-1
	found = false
	# check if we reached dst with at least one hop to spare
	while not found and i>0
		i += -1
		if dstcls== $ip2cluster[hops.at(i)]
			found = true
		end
	end
	if found 
		# for now, removing the destination cluster
		# change to [0...i] to include it
		hops[0..i]=[]
		# remove cluster level loops
		if remove_loops
			curr_index=0
			clusters=hops.collect{|ip| $ip2cluster[ip]}
			while curr_index<(hops.length-1)
				hops[curr_index..(clusters.rindex(clusters.at(curr_index)))]=hops[curr_index]
				clusters[curr_index..(clusters.rindex(clusters.at(curr_index)))]=clusters[curr_index]
				curr_index+=1
			end
		end
		return hops	
	else
		return []
	end
end
# whether this destination is responsive but with ts=0
$ts_dst2stamps_zero = Hash.new(false)
# whether this particular src should use spoofed ts to that hop
$ts_src2hop2sendspoofed = Hash.new { |hash, src|  hash[src] = Hash.new(false)}
# whether this hop is thought to be responsive at all to this src
$ts_src2hop2responsive = Hash.new { |hash, src|  hash[src] = Hash.new(true)}
# nil means we issued the probe, did not get a response
$ts_src2probe2vp2result = Hash.new { |hash, key|  hash[key] = Hash.new { |in_hash, in_key|  in_hash[in_key] = Hash.new}}
# pass in a method to process probe results.  called once on each line of
# output from timestamps.  given the source and the line and the source
# (:non_spoofed in this case)
def issue_timestamps(src2probes,dirname, process_src_and_ts_and_vp)
	total_probes=0
	src2probes.each_pair{|s,probes|
		probes.each{|p|
			$ts_src2probe2vp2result[s][p][:non_spoofed]=nil
		}
		total_probes +=probes.length
	}
	$probe_counts["ts"] += total_probes
	$LOG.puts "Issuing timestamps: " + `date +%Y.%m%d.%H%M.%S`.chomp("\n") + " " + total_probes.to_s
	results=[]
	if $issue_probes
		begin
			ProbeController::issue_to_controller{|controller|
				results,unsuccessful_hosts,privates,blacklisted=controller.ts(src2probes, {  :retry => true, :backtrace => caller} )
			}
		rescue DRb::DRbConnError
			$LOG.puts "EXCEPTION! Controller refused connection to issue ts: " + $!.to_s, $DRB_CONNECT_ERROR
		end
	end
	results.each{|p|
		probes = p.at(0)
		src = p.at(1)
		if $log_probes
			`mkdir -p #{dirname}`
			f=nil
			begin
				f = File.new("#{dirname}/tsping.out." + src,  "wb")
				f.write(probes)
			ensure
				  f.close unless f.nil?
			end
		end

		probes.each_line{|r|
			process_src_and_ts_and_vp.call(src,r,:non_spoofed)
		}
	}
	return results
end

# pass in a method to process probe results.  called once on each line of
# output from timestamps.  given the source and the line
def issue_spoofed_timestamps(receiver2spoofer2probes,dirname, process_src_and_ts_and_vp)
	total_probes=0
	receiver2spoofer2probes.each_pair{|receiver,spoofer2probes|
		spoofer2probes.each_pair{|spoofer,probes|
			probes.each{|p|
				$ts_src2probe2vp2result[receiver][p][spoofer]=nil
			}
			total_probes +=probes.length
		}
	}
	$probe_counts["spoof-ts"] += total_probes
	$LOG.puts "Issuing spoofed_timestamps: " + `date +%Y.%m%d.%H%M.%S`.chomp("\n") + " " + total_probes.to_s
	results=[]
	if $issue_probes
		begin
			ProbeController::issue_to_controller{|controller|
				results,unsuccessful_hosts,privates,blacklisted=controller.spoof_ts(receiver2spoofer2probes, { :retry => true, :parallel_receivers => :all, :backtrace => caller})
			}
		rescue DRb::DRbConnError
			$LOG.puts "EXCEPTION: Controller refused connection to issue spoofed ts: " + $!.to_s, $DRB_CONNECT_ERROR
		end
	end
	results.each{|p|
		probes = p.at(0).at(0)
		spoofers_for_probes = p.at(0).at(1)
		src = p.at(1)
		spoofers_for_probes.collect!{|x| $pl_ip2host[x]}
		$LOG.puts "#{src} received #{spoofers_for_probes.length} total responses from #{spoofers_for_probes.join(" ")}"
		if probes.lines.count != spoofers_for_probes.length
			$LOG.puts "Mismatch between TS length and spoofer list length: #{probes.lines.count} vs #{spoofers_for_probes.length}"

		end
		if $log_probes
			`mkdir -p #{dirname}`
			# TODO: not logging spoofers?
			f=nil
			begin
				f = File.new("#{dirname}/spoof_tsping.out." + src,  "wb")
				f.write(probes)
			ensure
				  f.close unless f.nil?
			end
		end

		i=0
		probes.each_line{|probe|
			process_src_and_ts_and_vp.call(src,probe,spoofers_for_probes.at(i))
			i += 1
		}
	}
	return results
end

# assumes we issued the traceroutes already
# NOTE THAT THIS WILL MODIFY THE OBJECTS INSIDE THE INPUT ARRAY 
def reverse_hops_tr_to_src(reverse_traceroutes)
#JUSTINE
	reached=[]
	found_hops=[]
	no_hops=[]
	to_request = []
	src_dest_to_rtr = {}
	reverse_traceroutes.each{|revtr|
		src=$pl_host2ip[revtr.src]
		revtr.curr_path.path.at(-1).hops.each{|hop|
			if !(Inet::in_private_prefix? hop) then
				to_request << [hop, src]

				#Need this to be an array in case multiple RTRs to same dest arrive
				#at same hop
				src_dest_to_rtr[[hop,src]] = [] if src_dest_to_rtr[[hop,src]] == nil
				src_dest_to_rtr[[hop,src]] << revtr
			end
		}
	}
	wait = nil
	begin
	results = nil
	permissible_staleness = 15 # in minutes
	$LOG.puts "CHECKING FOR TRACEROUTES IN ATLAS"
	$LOG.puts "CHECKING FOR INTERSECTIONS AT: #{src_dest_to_rtr.keys.inspect}"
		ProbeController::issue_to_tr_atlas{|atlas|
			results = atlas.find_intersecting_traceroutes(to_request, permissible_staleness)
			results[:done].each{|key,value|
					$LOG.puts "FOUND TRtoSrc for #{key.inspect}"
					segment = TRtoSrcRevSegment.new(value, key[1], key[0])
					src_dest_to_rtr[key].each{|rtr|
						if(reached.index(rtr) == nil && rtr.add_background_tr_segment(segment)) then
							reached << rtr
						end
					}
			}
			wait = results[:wait]
		}

	rescue DRb::DRbConnError
		$LOG.puts "EXCEPTION! Server refused connection trying to get TR to srcs: " + $!.to_s, $DRB_CONNECT_ERROR
	end
		
	$LOG.puts "WAITING ON KEY: #{wait.inspect} FOR BACKGROUND TRACEROUTES"
	waiting_on = {}

	no_hops = reverse_traceroutes - reached
	
	return reached, found_hops, no_hops, wait, src_dest_to_rtr
end

def retreive_background_trs(reverse_traceroutes, some_hops, token, waiting_on)
	reached = []
	$LOG.puts "CHECKING KEY #{token.inspect} FOR COMPLETED TRACEROUTES"
	begin
	ProbeController::issue_to_tr_atlas{|atlas|
		results = atlas.retreive_trs(token)
		$LOG.puts "RESULTS FOR KEY #{token}: #{results.inspect}"
		return [], some_hops, reverse_traceroutes if results.nil? || results[:done].nil?
		results[:done].each{|key,value|
				segment = TRtoSrcRevSegment.new(value, key[1], key[0])
				begin #have been getting keys not in waiting on... where do they come from??
						waiting_on[key].each{|rtr|
							if(reverse_traceroutes.index(rtr) != nil && rtr.add_background_tr_segment(segment)) then
								$LOG.puts "FOUND TRtoSrc for #{key.inspect}"
								reverse_traceroutes.delete rtr
								reached << rtr if reached.index(rtr).nil?
							elsif(some_hops.index(rtr) != nil && rtr.add_background_tr_segment(segment)) then
								$LOG.puts "FOUND TRtoSrc for #{key.inspect}"
								some_hops.delete rtr
								reached << rtr if reached.index(rtr).nil?
							end
						}
				rescue NoMethodError=> e
					$LOG.puts "ERROR!!!"
					$LOG.puts "Waiting_On didn't contain key pair... ??"
					$LOG.puts "Expected: #{key.inspect}"
					$LOG.puts "Traceroutes: #{value.inspect}"
					$LOG.puts "Actual waiting_on was:"
					$LOG.puts waiting_on.inspect
					$LOG.puts "Exception was:"
					$LOG.puts e.inspect
					$LOG.puts e.backtrace
					exit
				end
		}
	}
	rescue DRb::DRbConnError
		$LOG.puts "EXCEPTION! Server refused connection trying to get TR to srcs: " + $!.to_s, $DRB_CONNECT_ERROR
	end

	return reached, some_hops, reverse_traceroutes
end


# if we send this many RR to a destination and it doesnt respond, give up
$MAX_UNRESPONSIVE=10

# given a set of partial reverse traceroutes,
# try to find reverse hops using RR option
# NOTE THAT THIS WILL MODIFY THE OBJECTS INSIDE THE INPUT ARRAY 
$BATCH_INIT_RR_VPS=true
def reverse_hops_rr(reverse_traceroutes,dirname)
	reached=[]
	found_hops=[]
	no_hops=[] # issued probes, no rev hops discovered
	no_vps=[]  # could not issue probes, all vps already used
	rrs_to_issue=[] # src, dst pairs
	receiver2spoofer2targets=Hash.new { |hash, key|  hash[key] = Hash.new { |inner_hash, inner_key| inner_hash[inner_key] = [] }}
	probe_requests={}
	if $BATCH_INIT_RR_VPS
		ReverseTraceroute::batch_initialize_rr_vps(reverse_traceroutes)
	end
	reverse_traceroutes.each{|revtr|
		vps,target=revtr.get_rr_vps(revtr.lastHop)
		if vps.nil?
			no_vps << revtr
		else	
			$LOG.puts "#{revtr.src} #{revtr.dst} #{target} using #{vps.join(" ")}"
			probe_requests[revtr]=[vps.clone,target]
			# delete out the ones we already issued
			cls=$rr_vps_by_cluster ? $ip2cluster[target] : target
			vps = vps - $rrs_src2dst2vp2revhops[revtr.src][cls].keys 
			if vps.include?(:non_spoofed)
				vps.delete(:non_spoofed)
				rrs_to_issue << [revtr.src, target]
			end
			if not vps.empty?
				vps.each{|vp|
					(receiver2spoofer2targets[$pl_ip2host[revtr.src]])[$pl_ip2host[vp]] << target
				}
			end
		end
	}
	if rrs_to_issue.length>0
		issue_recordroutes(rrs_to_issue.uniq,dirname + "/rr")
	end
	if receiver2spoofer2targets.length>0
		issue_spoofed_recordroutes(receiver2spoofer2targets,dirname + "/spoofed_rr")
	end
	probe_requests.each_pair{|revtr, vps_target|
		vps,target=*vps_target
		# look to see if i got new hops for it
		segments=[]
		vps.each{|vp|
			hops=$rrs_src2dst2vp2revhops[revtr.src][$rr_vps_by_cluster ? $ip2cluster[target] : target][vp]
			if not (hops.nil? or hops.empty?)
				# for every non-zero hop, build a revsegment
				hops.each_index{|i|
					next if hops.at(i)=="0.0.0.0"
					segments << (vp==:non_spoofed ? RRRevSegment.new(hops[0..i],revtr.src,target) : SpoofRRRevSegment.new(hops[0..i],revtr.src,target,vp))
				}
			end
		}
		if not (revtr.add_segments(segments))
			no_hops << revtr
		elsif revtr.reaches?
			reached << revtr
		else
			found_hops << revtr
		end
	}

	return reached, found_hops, no_hops, no_vps
end

# given a set of partial reverse traceroutes,
# try to find reverse hops using TS option
# get the ranked set of adjacents
# for each, the set of sources to try (self, spoofers)
# if you get a reply, see if it needs linux bug check
# or see if it is 0 and needs a technique for that, to isolate direction
# if you don't get a reply, try different source
# mark info per destination (current hop), then reuse with other adjacents as
# needed
# 
# each time we call this, it will try one potential adjacency per revtr
# (assuming one exists for that revtr).  at the end of execution, it should
# either have found that adjacency is a rev hop or found that it will not be
# able to determine that it is (either it isn't, or our techniques won't be
# able to tell us if it is)
#
# info i need for each:
# for revtr:s,d,r, the set of R left to consider, or if there are none
# for a given s,d pair, the set of VPs to try using-- start it at self + the
# good spoofers
# whether d is an overstamper
# whether d doesnt stamp
# whether d doesnt stamp but will respond
#
#
# FUTURE: could issue TR to R to get a set of adjacencies
# for now, i am not doing that.  if TS fails, then we issue a TR from the
# source and ASSUME
# NOTE THAT THIS WILL MODIFY THE OBJECTS INSIDE THE INPUT ARRAY 
$DUMMY_IP="128.208.3.77" # lindorf.cs.washington.edu
def reverse_hops_ts(reverse_traceroutes,dirname)
	reached=[]
	found_hops=[]
	no_hops=[] # issued probes, no rev hops discovered
	no_adjs=[]  # could not issue probes, all adjacents already used
	no_vps=[]  # could not issue probes, all vps already used

	# non spoofed TS i want to send
	# format is src-> [ [d1,ts1,ts2,...], [d2,ts1,ts2,...]...]
	ts_to_issue_src2probe=Hash.new{|h,k| h[k]=[]} 
	receiver2spoofer2probe=Hash.new { |hash, key|  hash[key] = Hash.new { |inner_hash, inner_key| inner_hash[inner_key] = [] }}

	dest_does_not_stamp=[]
	probe_requests={}
	reverse_traceroutes.each{|revtr|
		# TODO put in a check here: if i've tried all VPs for this and haven't got
		# a response, give up. for now, just going to choose N spoofers at
		# random each time, if i don't get a response i'll give up
		# the hash has a default value of true, not nil, so this defaults to
		# if not true; so only stores in no_vps if explicitly set to false
		if not $ts_src2hop2responsive[$pl_ip2host[revtr.src]][revtr.lastHop]
			no_vps << revtr
			$LOG.puts "Current hop #{revtr.lastHop} seems to be TS unresponsive for #{revtr.src} #{revtr.dst}"
			next
		end
		adjacents=revtr.get_ts_adjacents($ip2cluster[revtr.lastHop])
		if adjacents.nil?
			no_adjs << revtr
			$LOG.puts "No adjacents to #{revtr.lastHop} left to test for #{revtr.src} #{revtr.dst}"
		else	
			probe_requests[revtr]=adjacents.clone
			# TODO: store the results of earlier probes somewhere, and reuse them
			# here, deleting out ones that i've already issued like i do in RR
			# delete out the ones we already issued
			if $ts_dst2stamps_zero[revtr.lastHop]
				$LOG.puts "Current hop #{revtr.lastHop} stamps 0, so not asking for stamp for #{revtr.src} #{revtr.dst}"
				adjacents.each{|a|
					dest_does_not_stamp << [$pl_ip2host[revtr.src],revtr.lastHop,a]
				}
			elsif not $ts_src2hop2sendspoofed[$pl_ip2host[revtr.src]][revtr.lastHop]
				adjacents.each{|a|
					ts_to_issue_src2probe[$pl_ip2host[revtr.src]] << [revtr.lastHop, revtr.lastHop, a, a, $DUMMY_IP]
				}
			else
				spfs=ReverseTraceroute::get_timestamp_spoofers($pl_ip2host[revtr.src], revtr.lastHop)
				adjacents.each{|a|
					spfs.each{|s|
						receiver2spoofer2probe[$pl_ip2host[revtr.src]][s] << [revtr.lastHop, revtr.lastHop, a, a, $DUMMY_IP]
					}
				}
				# if we haven't already decided whether it is responsive,
				# we'll set it to false, then change to true if we get one
				if not $ts_src2hop2responsive[$pl_ip2host[revtr.src]].has_key?(revtr.lastHop)
					$ts_src2hop2responsive[$pl_ip2host[revtr.src]][revtr.lastHop]=false
				end
			end
		end
	}
	rev_hops_src_dst2rev_seg = Hash.new{|h,k|h[k]=[]}
	linux_bug_to_check_srcdstvp2revhops = Hash.new{|h,sdv| h[sdv]=[]}

	process_ts_check_for_rev_hop = lambda{|src, probe,vp|
		info=probe.chomp("\n").split(" ")
		dst=info.at(0)
		ts1ip = info.at(1)
		ts1 = info.at(2).to_i
		ts2ip = info.at(3)
		ts2 = info.at(4).to_i
		ts3ip = info.at(5)
		ts3 = info.at(6).to_i
		seg_class=SpoofTSAdjRevSegment
		# if i got a response, must not be filtering, so dont need to use
		# spoofing
		if vp==:non_spoofed
			$ts_src2hop2sendspoofed[$pl_ip2host[src]][dst]=false
			seg_class=TSAdjRevSegment
		end
		$ts_src2hop2responsive[$pl_ip2host[src]][dst]=true
		
		if ts3!=0
			# if the 3rd slot is stamped, rev hop
			rev_hops_src_dst2rev_seg[[$pl_ip2host[src],dst]] << seg_class.new([ts3ip],$pl_ip2host[src],dst,false,vp)
			$LOG.puts "TS probe is #{vp} #{probe.chomp("\n")}: reverse hop!"
		elsif ts2!=0
			if ( ts2 - ts1 > 3 ) or ( ts2 < ts1 )
				# if 2nd slot is stamped w/ an increment from 1st, rev hop
				rev_hops_src_dst2rev_seg[[$pl_ip2host[src],dst]] << seg_class.new([ts2ip],$pl_ip2host[src],dst,false,vp)
				$LOG.puts "TS probe is #{vp} #{probe.chomp("\n")}: reverse hop!"
			else
				# else, if 2nd stamp is close to 1st, need to check for linux bug
				linux_bug_to_check_srcdstvp2revhops[[$pl_ip2host[src],dst,$pl_ip2host[vp]]] << ts2ip
				$LOG.puts "TS probe is #{vp} #{probe.chomp("\n")}: need to test for linux bug"
			end
		elsif ts1==0
			# if dst responds, does not stamp, can try advanced techniques
			$LOG.puts "TS probe is #{vp} #{probe.chomp("\n")}: destination does not stamp"
			$ts_dst2stamps_zero[dst]=true
			dest_does_not_stamp << [$pl_ip2host[src],dst,ts2ip]
		else
			$LOG.puts "TS probe is #{vp} #{probe.chomp("\n")}: no reverse hop found"
		end
	}
	if ts_to_issue_src2probe.length>0
		ts_to_issue_src2probe.each_value{|v| v.uniq!}
		ts_to_issue_src2probe.each_pair{|src,probes|
			probes.each{|p|
				next if $ts_src2hop2sendspoofed[$pl_ip2host[src]].has_key?(p.at(0))
				# set it to true, then change it to false if we get response
				$ts_src2hop2sendspoofed[$pl_ip2host[src]][p.at(0)]=true
			}
		}
		issue_timestamps(ts_to_issue_src2probe,dirname + "/ts",process_ts_check_for_rev_hop)
		ts_to_issue_src2probe.each_pair{|src,probes|
			probes.each{|p|
				# if we got a reply, would have set sendspoofed to false
				# so it is still true, we need to try to find a spoofer
				if $ts_src2hop2sendspoofed[$pl_ip2host[src]][p.at(0)]
					my_spoofers = ReverseTraceroute::get_timestamp_spoofers($pl_ip2host[src], p.at(0)).each{|s|
						receiver2spoofer2probe[$pl_ip2host[src]][s] << p
					}
					# if we haven't already decided whether it is responsive,
					# we'll set it to false, then change to true if we get one
					if not $ts_src2hop2responsive[$pl_ip2host[src]].has_key?(p.at(0))
						$ts_src2hop2responsive[$pl_ip2host[src]][p.at(0)]=false
					end
				end
			}
		}
	end
	# TODO: can also keep track in there which spoofers it responds to
	if receiver2spoofer2probe.length>0
		issue_spoofed_timestamps(receiver2spoofer2probe,dirname + "/ts_spoof", process_ts_check_for_rev_hop)
	end

	if linux_bug_to_check_srcdstvp2revhops.length>0
		linux_checks_src2probe=Hash.new{|h,k| h[k]=[]} 
		linux_checks_spoofed_receiver2spoofer2probe=Hash.new { |hash, key|  hash[key] = Hash.new { |inner_hash, inner_key| inner_hash[inner_key] = [] }}
		linux_bug_to_check_srcdstvp2revhops.each_key{|sdvp|
			src,dst,vp=sdvp
			p=[dst,dst,$DUMMY_IP, $DUMMY_IP]
			if vp==:non_spoofed
				linux_checks_src2probe[src] << p 
			else
				linux_checks_spoofed_receiver2spoofer2probe[src][vp] << p
			end
		}
		linux_checks_src2probe.each_value{|v| v.uniq!}
		linux_checks_spoofed_receiver2spoofer2probe.each_value{|spoofer2probe|
			spoofer2probe.each_value{|probes| probes.uniq!}
		}
		process_ts_check_for_linux_bug = lambda{|src, probe,vp|
			info=probe.chomp("\n").split(" ")
			dst=info.at(0)
			ts1ip = info.at(1)
			ts1 = info.at(2).to_i
			ts2ip = info.at(3)
			ts2 = info.at(4).to_i
			seg_class=SpoofTSAdjRevSegment
			# if i got a response, must not be filtering, so dont need to use
			# spoofing
			if vp==:non_spoofed
				$ts_src2hop2sendspoofed[$pl_ip2host[src]][dst]=false
				seg_class=TSAdjRevSegment
			end
			if ts2!=0
				$LOG.puts "TS probe is #{vp} #{probe.chomp("\n")}: linux bug!"
				# TODO keep track of linux bugs
				# as least once, i observed a bug not stamp one probe, so
				# this is important
				# probably then want to do the checks for revhops after
				# all spoofers that are trying have tested for linux bug
			else
				$LOG.puts "TS probe is #{vp} #{probe.chomp("\n")}: not linux bug!"
				linux_bug_to_check_srcdstvp2revhops[[$pl_ip2host[src],dst,$pl_ip2host[vp]]].each{|revhop|

					rev_hops_src_dst2rev_seg[[$pl_ip2host[src],dst]] << seg_class.new([revhop],$pl_ip2host[src],dst,false,$pl_ip2host[vp])
					$LOG.puts "Declaring #{revhop} reverse hop!"
				}
			end
		}
		issue_timestamps(linux_checks_src2probe,dirname + "/ts/linux",process_ts_check_for_linux_bug)
		issue_spoofed_timestamps(linux_checks_spoofed_receiver2spoofer2probe,dirname + "/ts_spoof/linux",process_ts_check_for_linux_bug)
	end
	receiver2spoofer2probe.clear
	# format is dest_does_not_stamp << [$pl_ip2host[src],dst,ts2ip]
	dest_does_not_stamp.each{|probe|
		src,dst,adj=*probe
		ReverseTraceroute::get_timestamp_spoofers(src,dst).each{|s|
			receiver2spoofer2probe[src][s] << [dst,adj,adj,adj,adj]
		}
	}
	# if i get the response, need to then do the non-spoofed version
	# for that, i can get everything i need to know from the probe
	# send the duplicates
	# then, for each of those that get responses but don't stamp
	# i can declare it a revhop-- i just need to know which src to declare it
	# for
	# so really what i need is a map from VP,dst,adj to the list of
	# sources/revtrs waiting for it
	dest_does_not_stamp_to_verify_spoofer2probe=Hash.new{|h,s| h[s]=[] }
	vp_dst_adj2interested_srcs=Hash.new{|h,s| h[s]=[] }
	process_ts_dest_does_not_stamp = lambda{|src, probe,vp|
		info=probe.chomp("\n").split(" ")
		dst=info.at(0)
		ts1ip = info.at(1)
		ts1 = info.at(2).to_i
		ts2ip = info.at(3)
		ts2 = info.at(4).to_i
		ts4ip = info.at(7)
		ts4 = info.at(8).to_i
		# if 2 stamps, we assume one was forward, one was reverse
		# if 1 or 4, we need to verify it was reverse
		# 3 should not happen, according to justine
		if ts2!=0 and ts4==0
			# declare reverse hop
			rev_hops_src_dst2rev_seg[[$pl_ip2host[src],dst]] << SpoofTSAdjRevSegmentTSZeroDoubleStamp.new([ts2ip],$pl_ip2host[src],dst,false,vp)
			$LOG.puts "TS probe is #{vp} #{probe.chomp("\n")}: reverse hop from dst that stamps 0!"
		elsif ts1!=0
			$LOG.puts "TS probe is #{vp} #{probe.chomp("\n")}: dst does not stamp, but spoofer #{vp} got a stamp"
			dest_does_not_stamp_to_verify_spoofer2probe[vp] << [dst,ts1ip,ts1ip,ts1ip,ts1ip]
			# store something
			vp_dst_adj2interested_srcs[[vp,dst,ts1ip]] << $pl_ip2host[src]
		else 
			$LOG.puts "TS probe is #{vp} #{probe.chomp("\n")}: no reverse hop for dst that stamps 0"
		end
	}
	if not dest_does_not_stamp.empty?
		$LOG.puts "Issuing for dest does not stamp" 
		issue_spoofed_timestamps(receiver2spoofer2probe, dirname + "/ts/dst_does_not_stamp",process_ts_dest_does_not_stamp)
	end

	# TODO: add redundancy to these probes
	# TODO: make the block: each time you get a response, add the key
	# if you don't get a response, add it with false
	# then at the end
	if not dest_does_not_stamp_to_verify_spoofer2probe.empty?
		dest_does_not_stamp_to_verify_spoofer2probe.each_pair{|vp, probes|
			dest_does_not_stamp_to_verify_spoofer2probe[vp]=(probes + probes + probes).sort_by{rand}
		}
		maybe_revhop_vp_dst_adj2bool = Hash.new(false)
		rev_hops_vp_dst2rev_seg = Hash.new{|h,k|h[k]=[]}
		process_ts_dest_does_not_stamp_to_verify = lambda{|src, probe,vp|
			info=probe.chomp("\n").split(" ")
			dst=info.at(0)
			ts1ip = info.at(1)
			ts1 = info.at(2).to_i
			if ts1==0
				$LOG.puts "Reverse hop! TS probe is #{vp} #{probe.chomp("\n")}: dst does not stamp, but spoofer #{vp} got a stamp and didn't directly"
				maybe_revhop_vp_dst_adj2bool[[src,dst,ts1ip]]=true
			else
				vp_dst_adj2interested_srcs.delete([src,dst,ts1ip])
				$LOG.puts "Can't verify reverse hop!  TS probe is #{vp} #{probe.chomp("\n")}: potential hop stamped on non-spoofed path for VP"
			end
		}
		$LOG.puts "Issuing to verify for dest does not stamp" 
		issue_timestamps(dest_does_not_stamp_to_verify_spoofer2probe,dirname + "/ts/dst_does_not_stamp/verify",process_ts_dest_does_not_stamp_to_verify)
		maybe_revhop_vp_dst_adj2bool.each_key{|v|
			vp,dst,adj=*v
			vp_dst_adj2interested_srcs[[vp,dst,adj]].each{|orig_src|
				rev_hops_src_dst2rev_seg[[$pl_ip2host[orig_src],dst]] << SpoofTSAdjRevSegmentTSZeroDoubleStamp.new([adj],$pl_ip2host[orig_src],dst,false,$pl_ip2host[vp])
			}
		}

	end

	# Ping V/S->R:R',R',R',R'
	# (i think, but justine has it nested differently) if stamps twice,
	# declare rev hop, # else if i get one:
	# if i get responses:
	# n? times: Ping V/V->R:R',R',R',R'
	# if(never stamps) //could be a false positive, maybe R' just didn't feel
	# like stamping this time 
	# 				return R'
	# 	if stamps more than once, decl
	# TODO: at the moment i'm ignoring adjacents, which ones i asked for, etc
	probe_requests.each_pair{|revtr, adjacents|
		if rev_hops_src_dst2rev_seg.has_key?([$pl_ip2host[revtr.src],revtr.lastHop])
			if not (revtr.add_segments(rev_hops_src_dst2rev_seg[[$pl_ip2host[revtr.src],revtr.lastHop]]))
				no_hops << revtr
			elsif revtr.reaches?
				reached << revtr
			else
				found_hops << revtr
			end
		else
			no_hops << revtr
		end

	}
	return reached, found_hops, no_hops, no_vps, no_adjs
end

# NOTE THAT THIS WILL MODIFY THE OBJECTS INSIDE THE INPUT ARRAY 
def reverse_hops_assume_symmetric(reverse_traceroutes,dirname)
	reached=[]
	found_hops=[]
	no_hops=[]
	trs_to_issue=[]
	reverse_traceroutes.each{|revtr|
		# if last hop is assumed, add one more from that tr
		if (revtr.curr_path.path.at(-1).class==DstSymRevSegment) 
			$LOG.puts "Backing off along current path for #{revtr.src} #{revtr.dst}"
			# need to not ignore the hops in the last segment, so can't just
			# call add_hops!(revtr.hops + revtr.deadends)
			added=revtr.add_and_replace_segment(revtr.curr_path.path.at(-1).clone.add_hop!(revtr.curr_path.path[0...-1].collect{|seg| seg.hops}.flatten + revtr.deadends))
			if added
				if revtr.reaches?
					reached << revtr
				else
					found_hops << revtr
				end
				next
			end
		end
		if not ($trs_src2dst2path[revtr.src].has_key?($ip2cluster[revtr.lastHop]))
			trs_to_issue << [revtr.src, revtr.lastHop]
		end
	}
	if trs_to_issue.length>0
		issue_traceroutes(trs_to_issue.uniq,dirname)
	end
	# if the last hop is not a symmetric assumption, 
	# or if it is, but lead to a deadend
	# then we have to add from a traceroute to the current hop
	((reverse_traceroutes - reached) - found_hops).each{|revtr|
		tr = $trs_src2dst2path[revtr.src][$ip2cluster[revtr.lastHop]]
		if (not tr.nil?) and (not tr.empty?) and $ip2cluster[tr.at(-1)]==$ip2cluster[revtr.lastHop]
			$LOG.puts "Traceroute to #{revtr.lastHop} reaches for #{revtr.src} #{revtr.dst}"
			if not (revtr.add_segments([DstSymRevSegment.new(revtr.src, revtr.lastHop, tr, 1, revtr.hops + revtr.deadends)]))
				no_hops << revtr
			elsif revtr.reaches?
				reached << revtr
			else
				found_hops << revtr
			end
		else
			no_hops << revtr
		end
	}
	return reached, found_hops, no_hops
end

# should i check that the destination is reachable? not checking
# that the pair is valid? (meaning, i guess that the source is a working VP)
# not checking
# passed in dir should be something like:
# dirname + "/rnd_" + ( rnd < 10 ? "0" + rnd.to_s : rnd.to_s ) +
#
# return reached, found_hops, failed/no_hops
def reverse_hops( reverse_traceroutes, dirname) 
 	if reverse_traceroutes.empty?
		return [], [], []
	end

	reached, found_hops, no_hops = reverse_hops_tr_to_src(reverse_traceroutes)
	reached2=[]
	found_hops2=[]
	no_vps=[]
	subrnd = 0
	while not no_hops.empty? 
		r, f, no_hops, v = reverse_hops_rr(no_hops, dirname +  "/rr/set_" + ( subrnd < 10 ? "0" + subrnd.to_s : subrnd.to_s ) )
		reached2 += r
		found_hops2 += f
		no_vps += v
		subrnd += 1
	end
	reached3=[]
	found_hops3=[]
	no_hops=no_vps
	no_vps=[]
	no_adj=[]
	subrnd = 0
	while not no_hops.empty? 
		r, f, no_hops, v, a = reverse_hops_ts(no_hops,dirname + "/ts/set_" + ( subrnd < 10 ? "0" + subrnd.to_s : subrnd.to_s ) )
		reached3 += r
		found_hops3 += f
		no_vps += v
		no_adj += a
		subrnd += 1
	end
	reached4, found_hops4, no_hops =  reverse_hops_assume_symmetric( no_vps + no_adj,dirname  + "/tr")
	reached += reached2 + reached3 + reached4
	found_hops = found_hops + found_hops2 + found_hops3 + found_hops4
	return reached, found_hops, no_hops
end

# intended as a wrapper when you just want one hop, not the whole path
# given a set of pairs, return the next hop back from each, plus the ones for
# which we have to assume a hop or which we can't find a hop at all
# returned hops are [ [src,dst], [hop]]
def reverse_hop_for_pairs( pairs, dirname )
	reverse_traceroutes=[]
	pairs.each{|pair|
		src=pair.at(0)
		dst=pair.at(1)
		reverse_traceroutes << ReverseTraceroute.new(src,dst)
	}
	reached, found_hops, no_hops = reverse_hops( reverse_traceroutes, dirname) 
	assume=[]
	measure=[]
	failed=[]
	(reached+found_hops).each{|revtr|
		if (revtr.curr_path.path.at(-1).class==DstSymRevSegment) 
			assume << [[revtr.src, revtr.dst], revtr.lastHop]
		else
			(0..(revtr.hops.length-2)).each{|i|
				measure << [[revtr.src, revtr.hops.at(i)], revtr.hops.at(i+1)]
			}
		end
	}
	no_hops.each{|revtr|
		failed << [[revtr.src, revtr.dst], nil]
	}
	return measure, assume, failed
end

# whether or not we will try to measure to a non-responsive destination
$dst_must_be_reachable=true
$probe_counts=Hash.new(0)
# return reached, failed, reached_trivial, dst_not_reachable 
# if block given, will yield <:type>,[revtrs] periodically, where
# <:type> is one of :reached,:failed,:reached_trivial,:dst_not_reachable
# and [revtrs] is non-empty array
def reverse_traceroute( pairs, dirname, backoff_endhost=true)
	
	#Variables to store progress/data
	$probe_counts.clear
	timebegin=`date +%s`.to_i
	reverse_traceroutes=[]
	initial_reverse_traceroutes=[]
	pairs.each{|pair|
		src=pair.at(0)
		dst=pair.at(1)
		initial_reverse_traceroutes << ReverseTraceroute.new(src,dst)
		reverse_traceroutes << ReverseTraceroute.new(src,dst)
	}
	reached=[]
	failed=[]
	reached_trivial=[]
	dst_not_reachable=[]
	rnd=0

	#Make sure we are able to reach host / actually want to issue ReVTR / start from next-hop router instead of end host.
	if backoff_endhost or $dst_must_be_reachable
		reached_trivial, reverse_traceroutes_back_off, dst_not_reachable =  reverse_hops_assume_symmetric(reverse_traceroutes,dirname + "/rnd_" + ( rnd < 10 ? "0" + rnd.to_s : rnd.to_s ) + "/tr")
		yield(:reached_trivial,reached_trivial) if block_given? and not (reached_trivial.nil? or reached_trivial.empty?)
		yield(:dst_not_reachable,dst_not_reachable) if block_given? and not (dst_not_reachable.nil? or dst_not_reachable.empty?)
		if backoff_endhost
			reverse_traceroutes=reverse_traceroutes_back_off
		else
			unreachable_pairs=Hash.new
			dst_not_reachable.each{|rtr|
				unreachable_pairs[[rtr.src,rtr.dst]] =true
			}
			# if we aren't backing off, we didnt really reach anything yet
			reverse_traceroutes=initial_reverse_traceroutes
			reverse_traceroutes.delete_if{|rtr|
				unreachable_pairs[[rtr.src,rtr.dst]]
			}
			reached_trivial=[]
		end
		(reached_trivial+reverse_traceroutes).each{|rtr|
			$LOG.puts "Fwd #{rtr.src} to #{rtr.dst}: #{$trs_src2dst2path[rtr.src][$ip2cluster[rtr.dst]].join(" ")}"
		}
		reached_trivial.each{|rtr|
			if $dump_logs
				$stdout.puts "RTR #{rtr.src} #{rtr.dst} #{rtr.symmetric_assumptions} #{rtr.curr_path.hops.join(" ")} []"
				begin
					dumpfile = File.new("#{dirname}/dump.out.#{rtr.src}_#{rtr.dst}",'w')
					dumpfile.write Marshal.dump(rtr.curr_path)
				ensure
					dumpfile.close
				end
			end
			$LOG.puts rtr.curr_path.to_s(true)
		}
	end
	dst_not_reachable.each{|rtr|
		$LOG.puts "UNREACHABLE #{rtr.src} #{rtr.dst}"
	}

	done=false
	if reverse_traceroutes.empty?
		done=true
	end

	#Actually issue the reverse traceroute (loop)
	while not done
		rnd += 1

		#Look for traceroutes
		reached_rnd, found_hops, no_hops, tr_token, waiting_on = reverse_hops_tr_to_src(reverse_traceroutes)
		yield(:reached,reached_rnd) if block_given? and not (reached_rnd.nil? or reached_rnd.empty?)

		#Issue Record Routes
		reached2=[]
		found_hops2=[]
		no_vps=[]
		subrnd = 0
		while not no_hops.empty? 
			r, f, no_hops, v = reverse_hops_rr(no_hops, dirname + "/rnd_" + ( rnd < 10 ? "0" + rnd.to_s : rnd.to_s ) + "/rr/set_" + ( subrnd < 10 ? "0" + subrnd.to_s : subrnd.to_s ) )
			reached2 += r
			yield(:reached,r) if block_given? and not (r.nil? or r.empty?)
			found_hops2 += f
			no_vps += v
			subrnd += 1
		end
		reached_rnd += reached2
		found_hops += found_hops2

		#Issue Timestamps
		reached3=[]
		found_hops3=[]
		no_hops=no_vps
		no_vps=[]
		no_adj=[]
		subrnd = 0
		while not no_hops.empty? 
			r, f, no_hops, v, a = reverse_hops_ts(no_hops,dirname + "/rnd_" + ( rnd < 10 ? "0" + rnd.to_s : rnd.to_s ) + "/ts/set_" + ( subrnd < 10 ? "0" + subrnd.to_s : subrnd.to_s ) )
			reached3 += r
			yield(:reached,r) if block_given? and not (r.nil? or r.empty?)
			found_hops3 += f
			no_vps += v
			no_adj += a
			subrnd += 1
		end
		no_hops = no_vps + no_adj
		reached_rnd += reached3
		found_hops += found_hops3
		
		#Add here a return to TS request
		reached_tmp, found_hops, no_hops = retreive_background_trs(no_hops, found_hops, tr_token, waiting_on)
		reached_rnd += reached_tmp
		yield(:reached,reached_tmp) if block_given? and not (reached_tmp.nil? or reached_tmp.empty?)


		#Assume symmetric
		
		reached4, found_hops4, no_hops =  reverse_hops_assume_symmetric( no_hops,dirname + "/rnd_" + ( rnd < 10 ? "0" + rnd.to_s : rnd.to_s ) + "/tr")
		yield(:reached,reached4) if block_given? and not (reached4.nil? or reached4.empty?)
		reached_rnd += reached4
		found_hops += found_hops4

		#Finished, keep those ones that are done	
		reached += reached_rnd
		
		$LOG.puts "REACHED"
		reached_rnd.each{|rtr| 
			if $dump_logs
				tr_hops=[]
				if rtr.curr_path.lastSeg.class==TRtoSrcRevSegment
					tr_hops=[rtr.curr_path.lastSeg.hop] + rtr.curr_path.lastSeg.hops
				end
				$stdout.puts "RTR #{rtr.src} #{rtr.dst} #{rtr.symmetric_assumptions} #{rtr.curr_path.hops.join(" ")} [#{tr_hops.join(" ")}]"
				begin
					dumpfile = File.new("#{dirname}/dump.out.#{rtr.src}_#{rtr.dst}",'w')
					dumpfile.write Marshal.dump(rtr.curr_path)
				ensure
					dumpfile.close
				end
			end
			$LOG.puts rtr.curr_path.to_s(true)
		}
		$LOG.puts "FOUND"
		found_hops.each{|x| $LOG.puts x.curr_path.to_s(true)}
		$LOG.puts "NONE"
		no_hops.each{|x| $LOG.puts x.curr_path.to_s(true)}


		failed_rnd = []
		no_hops.each{|revtr|
			revtr.fail_curr_path
			if revtr.failed?(backoff_endhost)
				failed_rnd << revtr
			end
		}
		no_hops = no_hops - failed_rnd
		failed += failed_rnd
		yield(:failed,failed_rnd) if block_given? and not (failed_rnd.nil? or failed_rnd.empty?)
		$LOG.puts "FAILED"

		failed_rnd.each{|rtr| 
			$LOG.puts rtr.to_s(true) 
			$stdout.puts "NOPATH #{rtr.src} #{rtr.dst}"
		}
		if no_hops.length==0 and found_hops.length==0
			done=true
		else
			reverse_traceroutes = no_hops + found_hops
		end
		$LOG.puts "--------"
	end
	timeend=`date +%s`.to_i
	$LOG.puts "Total time: #{timeend-timebegin}"
	$LOG.puts "Total probes: " + $probe_counts.collect{|k,v| "#{k}=#{v}"}.join(" ")
	return reached, failed, reached_trivial, dst_not_reachable 
end

# DEPRECATED
def issue_reverse_traceroutes(pairs,outdir,backoff)

	#trs_to_src_dir="/homes/network/ethan/timestamp/reverse_traceroute/reverse_traceroute/trs_to_src_fake"

	reached, failed, reached_trivial, dst_not_reachable = [],[],[],[]

	begin
		DRb.start_service
	rescue DRbBadURI
		$LOG.puts "Could not start DRb service: " + $!.to_s, $DRB_CONNECT_ERROR
	end

	measurable, privates, blacklisted = inspect_targets(pairs.collect { |pair| pair[1] }, [], [])

	private_pairs, blacklisted_pairs = [],[]
	
    pairs.delete_if { |pair|
		if privates.include?(pair[1])
			private_pairs << pair
			true
		elsif blacklisted.include?(pair.at(1))
			blacklisted_pairs << pair
			true
		else
			false
		end
	}

	srcs_that_need_traceroutes=[]

	pairs.each {|pair|
		srcs_that_need_traceroutes << $pl_host2ip[pair.at(0)]
	}

	
    # load_trs_to_src_from_directory(trs_to_src_dir)
	# make sure we have traceroutes to the source
	if not srcs_that_need_traceroutes.empty?
		$LOG.puts "Gathering traceroutes to srcs #{srcs_that_need_traceroutes.join(" ")}"
		begin
			ProbeController::issue_to_tr_server{|server|
				server.gather_trs_to(srcs_that_need_traceroutes,false)
			}
		rescue DRb::DRbConnError
			$LOG.puts "EXCEPTION! Server refused connection trying to gather TR to srcs: " + $!.to_s, $DRB_CONNECT_ERROR
		end
	end

	reached, failed, reached_trivial, dst_not_reachable = reverse_traceroute(pairs, outdir, backoff)

    return reached, failed, reached_trivial, dst_not_reachable, private_pairs, blacklisted_pairs
end

def get_reverse_traceroutes (requests_in, outdir)
    
    # Variables
    requests = requests_in.clone
    results = Hash.new { |h,k| h[k] = [] } 
    $request2result = Hash.new # return hash
	reached, failed, reached_trivial, dst_not_reachable = [],[],[],[]

    # Start DRb
	begin
		DRb.start_service
	rescue DRbBadURI
		$LOG.puts "Could not start DRb service: " + $!.to_s, $DRB_CONNECT_ERROR
	end

    # Determine destinations we aren't allowed to measure
	measurable, privates, blacklisted = inspect_targets(requests.collect { |r| r.destination }, [], [])

    # Deal with requests we won't bother to measure
    requests.delete_if { |r|
		if privates.include?(r.destination)
			$request2result[r] = [:private, nil]
            true
		elsif blacklisted.include?(r.destination)
            $request2result[r] = [:blacklisted, nil]
            true
		else
			false
		end
	}
   
#     # Tell server to issue traceroutes to the measurable destinations
#     srcs_that_need_traceroutes = requests.collect { |r| r.vantage_point.IP }.uniq
# 	if not srcs_that_need_traceroutes.empty?
# 		$LOG.puts "Gathering traceroutes to srcs #{srcs_that_need_traceroutes.join(" ")}"
# 		begin
# 			ProbeController::issue_to_tr_server { |server|
# 				server.gather_trs_to(srcs_that_need_traceroutes, false)
# 			}
# 		rescue DRb::DRbConnError
# 			$LOG.puts "EXCEPTION! Server refused connection trying to gather TR to srcs: " + $!.to_s, $DRB_CONNECT_ERROR
# 		end
# 	end

    # Actually issue the traceroutes
	#reached, failed, reached_trivial, dst_not_reachable = reverse_traceroute(requests.collect { |r| [r.vantage_point.vantage_point, r.destination] }.uniq, outdir, true)
    reverse_traceroute(requests.collect { |r| [r.vantage_point.vantage_point, r.destination] }.uniq, outdir, true) { |key, finished|
        $LOG.puts "Added #{finished.length} #{key}"
        results[key] += finished
    }

    # Reassociate with the requests
    requests.each { |request|
        #continue = false
        results.each { |key, result_array|
            result_array.each { |result|
            if (request.vantage_point.vantage_point == result.src && request.destination == result.dst)
                $request2result[request] = [key, result]
                break
            end
            }
        }
    }
    
    return $request2result

end

def get_pings(rtrs)
    
    # First of all, we need to get pings to show times for each hop
    # Three pings each!
    ping_targets=Hash.new { |hash,key| hash[key] = [] }
    rtrs.each { |rtr|
        ping_targets[rtr.src] += rtr.hops * 3
        ping_targets[rtr.src].delete("\*")
        ping_targets[rtr.src].delete("0.0.0.0")
    }
    
    # Issue the actual pings
    pings = Hash.new { |hash,key| hash[key] = [] }
    if ping_targets.length > 0
        begin
            ProbeController::issue_to_controller { |controller|
                ping_outputs, unsuccessful_hosts, privates, blacklisted = controller.ping(ping_targets, { :retry => true, :backtrace => caller} )
                ping_outputs.each { |ping_output,src|
                    ping_output.each_line { |ping|
                        info = ping.strip.split(" ")
                        pings[[src,info[0]]] << info[3].to_f
                    }
                }
            }
        rescue DRb::DRbConnError
            $LOG.puts "EXCEPTION! Controller refused connection, unable to issue pings: " + $!.to_s, $DRB_CONNECT_ERROR
        rescue
            $LOG.puts "Error getting pings from controller: " + $!.to_s, $GENERAL_ERROR
        end
    end
    
    return pings

end


def compare_to_html(tr_ips, revtr_ips) 
    
    parsed_traceroute = <<PARSE
<font size="2pt"><table border="0" cellspacing="0" cellpadding="0">
    <tr>
        <td bgcolor="#000000">
            <table border="0" cellspacing="1" cellpadding="4">
                <tr>
                    <th bgcolor="#FFFFCC">Hop</th>
                    <th bgcolor="#FFFFCC">TR IP</th>
                    <th bgcolor="#FFFFCC">Alias matches</th>
                    <th bgcolor="#FFFFCC">POP matches</th>
                </tr>
PARSE
    
    alias_matches = compare_with_cluster_hash(tr_ips, revtr_ips, create_cluster_hash($BETTER_ALIAS_CLUSTERS))
    pop_matches = compare_with_cluster_hash(tr_ips, revtr_ips, create_cluster_hash($BETTER_POP_CLUSTERS))
 
    # Next, generate a map of traceroute IPs to matches in the reverse traceroute
    tr_ips.each_index { |i|
        parsed_traceroute += <<PARSE
                <tr>
                    <td bgcolor="#FFFFFF">#{(i+1).to_s}</td>
                    <td bgcolor="#FFFFFF">#{tr_ips[i]}</td>
                    <td bgcolor="#FFFFFF">#{alias_matches[i]}</td>
                    <td bgcolor="#FFFFFF">#{pop_matches[i]}</td>
                </tr>
PARSE
    }
    
    parsed_traceroute += <<PARSE
            </table>
        </td>
    </tr>
</table></font>
PARSE

    return parsed_traceroute
    
end

def create_cluster_hash(file)
    
    cluster_hash = Hash.new { |hash, key| hash[key] = key }
    i = 0
    
    File.open(file) { |f|
        while (line = f.gets)
            line.strip.split(" ").each { |ip| cluster_hash[ip] = i }
            i += 1
        end
    }
    
    return cluster_hash
    
end

def compare_with_cluster_hash(tr_ips, revtr_ips, cluster_hash) 
    
    matches = Array.new
    
    # First, let's place all the IPs in the reverse traceroute into cluster groups
    revtr_clusters = Hash.new { |hash, item| hash[item] = [] }
    revtr_ips.each_index { |i|
        cluster_id = cluster_hash[revtr_ips[i]]
        revtr_clusters[cluster_id] << [i, revtr_ips[i]] if cluster_id != []
    }

    # Next, generate a map of traceroute IPs to matches in the reverse traceroute
    tr_ips.each_index { |i|
        matches[i] = revtr_clusters[cluster_hash[tr_ips[i]]].collect { |pairs| pairs.join(", ") }.join(" ")
    }

    return matches
    
end

# DEPRECATED
def reverse_traceroute_to_string(reached, failed, reached_trivial, dst_not_reachable, private_pairs, blacklisted_pairs)
	
    # First of all, we need to get pings to show times for each hop
    # Three pings each!
    ping_targets=Hash.new { |hash,key| hash[key] = [] }
	(reached+reached_trivial).each{|rtr|
		ping_targets[rtr.src] += rtr.hops * 3
		ping_targets[rtr.src].delete("\*")
		ping_targets[rtr.src].delete("0.0.0.0")
	}

	# Issue the actual pings
    pings = Hash.new { |hash,key| hash[key] = [] }
	if ping_targets.length > 0 
		begin
			ProbeController::issue_to_controller { |controller|
				ping_outputs, unsuccessful_hosts, privates, blacklisted = controller.ping(ping_targets, { :retry => true, :backtrace => caller} )
				ping_outputs.each { |ping_output,src|
					ping_output.each_line { |ping|
						info = ping.strip.split(" ")
                        pings[[src,info[0]]] << info[3].to_f
					}
				}
			}
		rescue DRb::DRbConnError
			$LOG.puts "EXCEPTION! Controller refused connection, unable to issue pings: " + $!.to_s, $DRB_CONNECT_ERROR
		rescue
			$LOG.puts "Error getting pings from controller: " + $!.to_s, $GENERAL_ERROR
		end
	end
    
    # Build an output that looks vaguely like a traceroute
	pair2results = Hash.new("")
	hops_seen=Hash.new(false)
	(reached+reached_trivial).each{|rtr|
		$LOG.puts rtr.curr_path.to_s(true)
		hops_seen.clear
		rtr.hops.each_index { |i|
			hop=rtr.hops[i]
			if $prune_loops
				next if hops_seen[hop]
				hops_seen[hop]=true
			end
			rtt=pings[[rtr.src,hop]]
			
            require 'resolv'
            presentation = Resolv.getname(hop) rescue ""

			if hop=="0.0.0.0" or hop=="\*"
				pair2results[[rtr.src,rtr.dst]] += "#{i.to_s.rjust(2)}  * * *\n"
			elsif rtt == []
				pair2results[[rtr.src,rtr.dst]] += "#{i.to_s.rjust(2)}  #{presentation} (#{hop}) *\n"
			else
				pair2results[[rtr.src,rtr.dst]] += "#{i.to_s.rjust(2)}  #{presentation} (#{hop}) #{rtt.join(" ms ")} ms\n"
			end
		}
	}

	failed.each{|rtr|
		pair2results[[rtr.src,rtr.dst]] += "No path found from #{rtr.dst} back to #{rtr.src}\n"
	}

	dst_not_reachable.each{|rtr|
		pair2results[[rtr.src,rtr.dst]] += "#{rtr.dst} is not reachable with a forward traceroute from #{rtr.src}, so no reverse traceroute attempted\n"
	}

	(private_pairs+blacklisted_pairs).each{|pair|
		pair2results[pair] += "We apologize, but the address #{pair.at(1)} is contained in a prefix that is either allocated for private use or whose owner has asked us not to probe it.  As such, we cannot measure a reverse path.\n"
	}

	return pair2results

end


# issue_traceroutes( pairs, ARGV[3] )
# $trs_src2dst2path.each_key{|src|
# 	$trs_src2dst2path[src].each_pair{|dst,path|
# 		if path.nil?
# 			puts src + " " + dst + " NIL"
# 		else
# 			puts src + " " + dst + " " + path.join(" ")
# 		end
# 	}
# }
# issue_recordroutes( pairs, ARGV[3] )
# site2spoofer=choose_one_spoofer_per_site
# receiver2spoofer2targets=Hash.new { |hash, key|  hash[key] = Hash.new { |inner_hash, inner_key| inner_hash[inner_key] = [] }}
# pairs.each{|pair|
# 	sites_for_target=vps.get_sites_for_ip(pair.at(1))
# 	if not sites_for_target.nil?
# 		spoofers_for_target=(sites_for_target & site2spoofer.keys).collect{|site| site2spoofer[site]}
# 		spoofers_for_target.each{|s|
# 			(receiver2spoofer2targets[pair.at(0)])[s] << pair.at(1)
# 		}
# 		$stdout.puts "Probing #{pair.at(1)} from #{spoofers_for_target.length}: #{spoofers_for_target.join(" ")}"
# 	else
# 		$LOG.puts "No VPs for #{pair.at(1)}"
# 	end
# 		
# }
# issue_spoofed_recordroutes( receiver2spoofer2targets, ARGV[4] )
# $rrs_src2dst2vp2revhops.each_key{|src|
# 	($rrs_src2dst2vp2revhops[src]).each_key{|dst|
# 		$rrs_src2dst2vp2revhops[src][dst].each_pair{|vp,path|
# 			if path.nil?
# 				puts src + " " + dst + " " + vp + " NIL"
# 			else
# 				puts src + " " + dst + " " + vp.to_s + " " + path.join(" ")
# 			end
# 		}
# 	}
# }
# 
# issue_traceroutes( pairs, ARGV[4] )
# ($trs_src2dst2path).each_key{|src|
# 	$trs_src2dst2path[src].each_pair{|dst,path|
# 		if path.nil?
# 			puts src + " " + dst  + " NIL"
# 		else
# 			puts src + " " + dst + " " + path.join(" ")
# 		end
# 	}
# }

# when to use cluster vs dst?  in particular, when i choose spoofers it is
# currently per cluster
# need to make sure i am consistent about using IP vs hostname, for instance
# when i srote measurements in a hash
# peter's tool doesn't expect pairs, so maybe i shouldn't give pairs
