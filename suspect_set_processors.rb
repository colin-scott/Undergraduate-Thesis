#!/homes/network/revtr/ruby/bin/ruby
# These modules encapsulate the code for outage correlation.
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

require 'utilities'
require 'db_interface'
require 'failure_isolation_consts'

# initializer contract:
#   - takes a MergedOutage object as param
#   - returns a set of suspects
class Initializer
    def initialize(registrar, db, logger)
        @registrar = registrar
        @db = db
        @logger = logger

        # TODO: reload when data changes (every 5 min.)
        direction2hash = FailureIsolation.historical_pl_pl_hops
        @site2outgoing_hops = direction2hash[:outgoing]
        @site2incoming_hops = direction2hash[:incoming]
    end

    # (no correlation involved)
    def historical_revtr_dst2src(merged_outage)
        historical_revtrs = []
        merged_outage.each { |outage| historical_revtrs << outage.historical_revtr }

        historical_revtr_hops = historical_revtrs.find_all { |revtr| !revtr.nil? && revtr.valid? }\
                                                 .map { |revtr| revtr.hops.map { |h| h.ip } }\
                                                 .flatten
        if historical_revtr_hops.empty?
            @logger.warn "historical_revtr_hops empty!" 
        else
            @logger.info "historical_revtr_hops passed!" 
        end

        return historical_revtr_hops
    end

    # actually trs, since we control the destination
    #
    # NOTE: these need to be /historical/, since hops on current
    # traceroutes are obviously working.
    #
    # So we do need a date field in the DB...
    #
    # XXX Basically redundant code with next method..
    def historical_revtrs_dst2vps(merged_outage)
        symmetric_outages = merged_outage.symmetric_outages
        return [] if symmetric_outages.empty?

        historical_path_hops = []

        symmetric_outages.each do |o|
            # select all historical hops on traceroutes where source is o.src
            # can be liberal, since it's for initializing, not pruning
            site = FailureIsolation.Host2Site[o.dst_hostname]
            if site.nil?
                @logger.warn "site for #{o.dst_hostname} not specified!" if site.nil?
            else
                historical_path_hops |= @site2outgoing_hops[site]
                if @site2outgoing_hops[site].empty?
                    @logger.info "no outgoing hops for site..."
                else
                    @logger.info "found outgoing hops for site!" 
                end
            end
        end

        return historical_path_hops
    end

    # All VPs -> source (ethan's PL traceroutes + isolation VPs -> source)
    def historical_trs_to_src(merged_outage)
        all_hops = []
        merged_outage.each do |o|
            # select all hops on historical traceroutes where destination is o.src
            # can be liberal, since it's for initializing, not pruning
            site = FailureIsolation.Host2Site[o.src]
            if site.nil?
                @logger.warn "site for #{o.src} not specified!" if site.nil?
            else
                all_hops |= @site2incoming_hops[site] unless site.nil?

                if @site2incoming_hops[site].empty?
                    @logger.info "no incoming hops for site..."
                else
                    @logger.info "found incoming hops for site!" 
                end
            end
        end 
        return all_hops
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
    Pruner::OrderedMethods = ["intersecting_traces_to_src", "pings_issued_before_suspect_set_processing", "trace_hops_src_to_dst",  "pings_from_source"]

    ## empty for now... revtr is far too slow...
    #def intersecting_revtrs_to_src(suspected_set, merged_outage)
    #    return []
    #end

    # second half of path splices
    #  TODO: ensure that traces are sufficiently recent (issued after outage
    #  began...)
    def intersecting_traces_to_src(suspect_set, merged_outage)
        to_remove = []
        merged_outage.each do |o|
            # select all hops on current traceroutes where destination is o.src
            site = FailureIsolation.Host2Site[o.src]
            @logger.warn "intersecting_traces_to_src, site nil! #{o.src}" if site.nil?
            hops_on_traces = FailureIsolation.current_hops_on_pl_pl_traces_to_site(@db, site) unless site.nil?
            if hops_on_traces.empty?
                @logger.warn "no hops on traces to site: #{site}"
            else
                @logger.info "found intersecting hops on traces to site: #{site}"
            end

            to_remove += hops_on_traces
        end

        return to_remove
    end

    def trace_hops_src_to_dst(suspect_set, merged_outage)
        # we have some set of preexisting pings.
        trace_hops = merged_outage.map { |o| o.tr }.find_all { |trace| trace.valid? }\
            .map { |trace| trace.hops.map { |hop| hop.ip } }.flatten.to_set.to_a
    end

    def pings_issued_before_suspect_set_processing(suspect_set, merged_outage)
          # TODO: is responsive_targets ip addresses?
        ping_responsive_hops = merged_outage.map { |o| o.responsive_targets }.flatten.to_set.to_a
    end

    # we want this method to be executed last...
    def pings_from_source(suspect_set, merged_outage)
        # now issue more pings!
        srcs = merged_outage.map { |o| o.src }

        # XXX WHY AREN'T YOU ISSUING?
        src2pingable_dsts = @registrar.all_pairs_ping(srcs, suspect_set.to_a)

        if !suspect_set.empty? and src2pingable_dsts.value_set.empty?
            @logger.warn "#{src2pingable_dsts.inspect} was empty?!" 
            @logger.warn "srcs: #{srcs.inspect} suspect_set: #{suspect_set.to_a.inspect}"
        else
            @logger.info "issued pings sucessfully!"
        end

        return src2pingable_dsts.value_set
    end
end

if $0 == __FILE__
    i = Initializer.new(nil,DatabaseInterface.new, LoggerLog.new($stderr))
end
