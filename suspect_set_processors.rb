#!/homes/network/revtr/ruby/bin/ruby
#
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
# TODO: we want accounting for where each target was initialized from and
# which pruner eliminated. Perhaps make a new object Suspect
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

# initializer contract:
#   - takes a MergedOutage object as param
#   - returns a set of suspects
class Initializer
    def initialize(registrar, db, logger)
        @registrar = registrar
        @db = db
        @logger = logger
        direction2hash = FailureIsolation.historical_pl_pl_hops
        @node2outgoing_hops = direction2hash[:outgoing]
        @node2incoming_hops = direction2hash[:incoming]
    end

    # (no correlation involved)
    def historical_revtr_dst2src(merged_outage)
        historical_revtrs = []
        merged_outage.each { |outage| historical_revtrs << outage.historical_revtr }

        historical_revtr_hops = historical_revtrs.find_all { |revtr| !revtr.nil? && revtr.valid? }\
                                                 .map { |revtr| revtr.hops }\
                                                 .flatten
        return historical_revtr_hops
    end

    # actually trs, since we control the destination
    #
    # NOTE: these need to be /historical/, since hops on current
    # traceroutes are obviously working.
    #
    # So we do need a date field in the DB...
    def historical_revtrs_dst2vps(merged_outage)
        symmetric_outages = merged_outage.symmetric_outages
        return [] if symmetric_outages.empty?

        historical_path_hops = []

        # contained in Ethan's trs
        # may have to map from hostname->site
        symmetric_outages.each do |o|
            # select all historical hops on traceroutes where source is o.src
            # XXX may have to map from hostname->site
            # can be liberal, since it's for initializing, not pruning
            historical_path_hops |= @node2outgoing_hops[o.dst_hostname]
        end

        return historical_path_hops
    end

    # All VPs -> source (ethan's PL traceroutes + isolation VPs -> source)
    def historical_trs_to_src(merged_outage)
        all_hops = []
        merged_outage.each do |o|
            # select all hops on historical traceroutes where destination is o.src
            # can be liberal, since it's for initializing, not pruning
            all_hops |= @node2incoming_hops[o.src]
        end 
        return all_hops
    end

    # all IPs in nearby prefixes
    def all_ips_in_vicinity(merged_outage)
        return []
    end
end

# pruner contract:
#   - takes a set of suspects, and a MergedOutage object
#   - prunes the set of suspects
#   - return value is ignored
class Pruner
    def initialize(registrar, db, logger)
        @registrar = registrar
        @db = db
        @logger = logger
    end

    # To specify an order for your methods to be executed in, add method names here, first to last
    Pruner::OrderedMethods = ["intersecting_traces_to_src", "pings_from_source"]

    # empty for now... revtr is far too slow...
    def intersecting_revtrs_to_src(suspected_set, merged_outage)
    end

    # first half of path splices
    #       actually trs, since we control the destination
    #
    # XXX This technique is a little more sketch... routing table entries
    # other destinations, but not necessarily the soure...
    def revtrs_dst2vps(suspected_set, merged_outage)

        #symmetric_outages = merged_outage.symmetric_outages
        #return if symmetric_outages.empty?

        #symmetric_outages.each do |o|
        #    # select all hops on current traceroutes where source is o.src
        #    # may have to map from hostname->site
        #     
        #end
    end

    # second half of path splices
    #  TODO: ensure that traces are sufficiently recent (issued after outage
    #  began...)
    def intersecting_traces_to_src(suspect_set, merged_outage)
        merged_outage.each do |o|
            # select all hops on current traceroutes where destination is o.src
            src_ip = @db.node_ip(o.src)
            next if src_ip.nil?
            suspect_set -= FailureIsolation::current_hops_on_pl_pl_traces_to_src_ip(src_ip)
        end
    end

    # we want this method to be executed last...
    def pings_from_source(suspect_set, merged_outage)
        # we have some set of preexisting pings.
        # issue more! 
        merged_outage.each do |o|

        end
    end
end

if $0 == __FILE__
    i = Initializer.new(nil,DatabaseInterface.new, LoggerLog.new($stderr))
end
