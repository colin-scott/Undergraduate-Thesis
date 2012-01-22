#!/homes/network/revtr/ruby-upgrade/bin/ruby

# These modules encapsulate the code for Arvind + Colin's "correlation"
# algorithm.
#
# Initializers populate the suspect set.
# 
# Pruners remove targets from the suspect set.
#
# What remains is returned as the suspected failure(s).
#
# To add more pruners or initializers, simply define a new
# instance method that conforms to the contract 
#
# For now, these are only invoked for reverse and bidirectional outages
#
# See outage.rb for the MergedOutage class definition. See hops.rb for a
# definition of the measurement data types.
#
# TODO: We want to prioritze the suspected failures in the case that more than
# one target remains in the suspect set. For example, the unresponsive router
# on the border of the "reachability horizon" is more interesting than
# randomly placed unresponsive routers.
#
# TODO: right now we take /all/ hops on historical traces as suspects.
#       might make sense to take only hops in the core, not on the edge
#
# TODO: wrap suspects in their own class.

require 'isolation_utilities.rb'
require 'db_interface'
require 'failure_isolation_consts'
require 'fileutils'

class Suspect
    attr_accessor :ip, :outage

    def initialize(ip, outage)
        @ip = ip
        @outage = outage
    end
end

# initializer contract:
#   - takes a MergedOutage object as param
#   - returns a set of suspects
class Initializer
    def initialize(registrar=nil, db=DatabaseInterface.new, logger=LoggerLog.new($stderr))
        @registrar = registrar
        @db = db
        @logger = logger

        # TODO: reload when data changes (every 5 min.)
        direction2hash = FailureIsolation.historical_pl_pl_hops
        @site2outgoing_hops = direction2hash[:outgoing]
        @site2incoming_hops = direction2hash[:incoming]
    end

    # Historical traces from isolation VPs -> targets
    def historical_trs_to_dst(merged_outage)
        historical_tr_hops = Set.new
        # TODO: possibly consider all isolation VPs' traces -> outage.dst?
        # For now, only sources involved in the outage
        merged_outage.each do |outage|
            target2trace = FailureIsolation.Node2Target2Trace[outage.src.downcase]
            next unless target2trace
            ttlhoptuples = target2trace[outage.dst] 
            next unless ttlhoptuples
            historical_tr_hops |= ttlhoptuples.map { |ttlhop| ttlhop[1] }
        end

        return historical_tr_hops
    end

    # (no correlation involved)
    def historical_revtr_dst2src(merged_outage)
        historical_revtr_suspects = []
        merged_outage.each do |outage|
            revtr = outage.historical_revtr
            next if revtr.nil? or !revtr.valid?

            suspects = revtr.hops.map { |h| Suspect.new(h.ip, outage) }
            historical_revtr_suspects += suspects
        end

        if historical_revtr_suspects.empty?
            @logger.warn "historical_revtr_hops empty!" 
        else
            @logger.debug "historical_revtr_hops passed!" 
        end

        return historical_revtr_suspects
    end

    # actually trs, since we control the destination
    #
    # NOTE: these need to be /historical/, since hops on current
    # traceroutes are obviously working.
    #
    # So we do need a date field in the DB...
    #
    # TODO: Basically redundant code with next method..
    def historical_revtrs_dst2vps(merged_outage)
        symmetric_outages = merged_outage.symmetric_outages
        return [] if symmetric_outages.empty?

        historical_path_suspects = []

        symmetric_outages.each do |o|
            # select all historical hops on traceroutes where source is o.src
            # can be liberal, since it's for initializing, not pruning
            site = FailureIsolation.Host2Site[o.dst_hostname]

            if site.nil?
                @logger.warn "site for #{o.dst_hostname} not specified!" if site.nil?
            else
                historical_path_suspects += @site2outgoing_hops[site].map { |ip| Suspect.new(ip, o) }

                if @site2outgoing_hops[site].empty?
                    @logger.warn "no outgoing hops for site..."
                else
                    @logger.debug "found outgoing hops for site!" 
                end
            end
        end

        return historical_path_suspects
    end

    # All VPs -> source (ethan's PL traceroutes + isolation VPs -> source)
    def historical_trs_to_src(merged_outage)
        all_suspects = []
        merged_outage.each do |o|
            # select all hops on historical traceroutes where destination is o.src
            # can be liberal, since it's for initializing, not pruning
            site = FailureIsolation.Host2Site[o.src]
            if site.nil?
                @logger.warn "site for #{o.src} not specified!" if site.nil?
            else
                all_suspects += @site2incoming_hops[site].map { |ip| Suspect.new(ip, o) } unless site.nil?

                if @site2incoming_hops[site].empty?
                    @logger.warn "no incoming hops for site..."
                else
                    @logger.debug "found incoming hops for site!" 
                end
            end
        end 
        return all_suspects
    end

    ## all IPs in nearby prefixes
    #def all_ips_in_vicinity(merged_outage)
    #    return []
    #end
end

# pruner contract:
#   - takes an immutable set of suspects, and a MergedOutage object
#   - returns a list of suspects to remove from the suspect set
class Pruner
    def initialize(registrar, db, logger)
        @registrar = registrar
        @db = db
        @logger = logger
    end

    # To specify an order for your methods to be executed in, add method names here, first to last
    Pruner::OrderedMethods = [:"intersecting_traces_to_src", :"pings_issued_before_suspect_set_processing", :"trace_hops_src_to_dst", :"pings_from_source"]

    ## empty for now... revtr is far too slow...
    #def intersecting_revtrs_to_src(suspected_set, merged_outage)
    #    return []
    #end

    # second half of path splices (hops on PL-PL traces to the source, issued
    # by Ethan's PL-PL system)
    #
    #  TODO: ensure that traces are sufficiently recent (issued after outage
    #  began...)
    def intersecting_traces_to_src(suspect_set, merged_outage)
        to_remove = []
        merged_outage.each do |o|
            # select all hops on current traceroutes where destination is o.src
            site = FailureIsolation.Host2Site[o.src]
            @logger.warn "intersecting_traces_to_src, site nil! #{o.src}" if site.nil?
            hops_on_traces = FailureIsolation.current_hops_on_pl_pl_traces_to_site(@db, site) unless site.nil?
            if hops_on_traces.nil? or hops_on_traces.empty?
                @logger.warn "no hops on traces to site: #{site}"
            else
                @logger.debug "found intersecting hops on traces to site: #{site}"
            end

            to_remove += hops_on_traces
        end

        return to_remove
    end

    # All hops seen on normal traceroutes from the sources (obviously
    # reachable)
    def trace_hops_src_to_dst(suspect_set, merged_outage)
        # we have some set of preexisting pings.
        trace_hops = merged_outage.map { |o| o.tr }.find_all { |trace| trace.valid? }\
            .map { |trace| trace.hops.map { |hop| hop.ip } }.flatten.to_set.to_a
    end

    # All hops which were pingable before the suspect set processing began
    def pings_issued_before_suspect_set_processing(suspect_set, merged_outage)
        # TODO: is responsive_targets ip addresses or hops?
        ping_responsive_hops = merged_outage.map { |o| o.responsive_targets.to_a }.flatten.to_set.to_a
    end

    # After all other measurements have been leveraged to prune suspects, issue pings from the
    # source to the remaining suspects.
    #
    # we want this method to be executed last...
    #
    # NOTE: we've been seeing an issue where VPs will consistently return
    # empty ping results. Could be related to the controller, not sure...
    def pings_from_source(suspect_set, merged_outage)
        # now issue more pings!
        srcs = merged_outage.map { |o| o.src }.uniq

        # The controller keeps returning null results, so we instead use
        # pptasks directly... cp aliasprobe to a different directory?
        if((srcs & FailureIsolation::PoisonerNames).empty?)
            responsive_targets = issue_pings_with_pptasks(srcs, suspect_set.to_a)
        else
            src2pingable = @registrar.all_pairs_ping(srcs, suspect_set.to_a)
            responsive_targets = src2pingable.value_set.to_a
        end

        if !suspect_set.empty? and (responsive_targets.nil? or responsive_targets.empty?)
            @logger.warn "responsive targets #{responsive_targets.inspect} was empty?!" 
            @logger.warn "srcs: #{srcs.inspect} suspect_set: #{suspect_set.to_a.inspect}"
        else
            @logger.debug "issued pings sucessfully!"
        end

        return responsive_targets
    end
     
    # private methods won't be picked up by the failure_analyzer
    private
    
    # The controller keeps returning null results, so we instead use
    # pptasks directly... cp aliasprobe to a different directory?
    # TODO: move me somewhere else.
    def issue_pings_with_pptasks(sources, targets)
        id = Thread.current.__id__

        # XXX: DOESN'T WORK FOR RIOT NODES!
        File.open("/tmp/sources#{id}", "w") { |f| f.puts sources.join "\n" } 
        File.open("/tmp/targets#{id}", "w") { |f| f.puts targets.join "\n" } 

        system "#{FailureIsolation::PPTASKS} scp #{FailureIsolation::MonitorSlice} /tmp/sources#{id} 100 100 \
                    /tmp/targets#{id} @:/tmp/targets#{id}"

        # TODO: don't assume eth0!
        results = Set.new(`#{FailureIsolation::PPTASKS} ssh #{FailureIsolation::MonitorSlice} /tmp/sources#{id} 100 100 \
                    "cd colin/Scripts; sudo 2>/dev/null ./aliasprobe 40 /tmp/targets#{id} eth0 | cut -d ' ' -f1 | sort | uniq"`.split("\n"))

        # TODO: I suspect that this block of code may be the cause of the
        # heap overflows....
        if results.empty?
            @logger.warn "pptasks returned empty results: srcs=#{sources.length} targets=#{targets.length}"
            uuid = (0...36).map { (97 + rand(25)).chr }.join
            FileUtils.mkdir_p("#{FailureIsolation::EmptyPingsLogDir}/#{uuid}")
            system %{#{FailureIsolation::PPTASKS} ssh #{FailureIsolation::MonitorSlice} /tmp/sources#{id} 100 100 "hostname --fqdn ; ps aux" > #{FailureIsolation::EmptyPingsLogDir}/#{uuid}/ps-aux}
            @logger.warn "logs at #{FailureIsolation::EmptyPingsLogDir}/#{uuid}"
        end

        result
    end
end

if $0 == __FILE__
    #i = Initializer.new(nil,DatabaseInterface.new, LoggerLog.new($stderr))
    pruner = Pruner.new(nil,DatabaseInterface.new, LoggerLog.new($stderr))

    puts pruner.issue_pings_with_pptasks(["mlab1.ath01.measurement-lab.org", "planetlab1.csuohio.edu"] , ["193.138.215.1", "193.138.212.6", "212.103.65.134", "217.11.217.229"]).inspect
end
