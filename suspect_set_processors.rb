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


# initializer contract:
#   - takes a MergedOutage object as param
#   - returns a set of suspects
class Initializer
    def initialize(registrar, db, logger)
        @registrar = registrar
        @db = db
        @logger = logger
    end

    # currently the only initializer implemented (no correlation involved)
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

        # contained in Ethan's trs
        # may have to map from hostname->site
        symmetric_outage.each do |o|
            # select all historical hops on traceroutes where source is o.src
            # may have to map from hostname->site
            # can be liberal, since it's for initializing, not pruning
        end
    end

    # All VPs -> source (ethan's PL traceroutes + isolation VPs -> source)
    def historical_trs_to_src(merged_outage)
        all_hops = []
        merged_outage.each do |o|
            # select all hops on historical traceroutes where destination is o.src
            # can be liberal, since it's for initializing, not pruning
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

    def pings_from_source(suspect_set, merged_outage)
        # we have some set of preexisting pings.
        # issue more! 
    end

    # empty for now... revtr is far too slow...
    def intersecting_revtrs_to_src(suspected_set, merged_outage)
    end

    # first half of path splices
    #       actually trs, since we control the destination
    #
    # This technique is a little more sketch... routing table entries
    # other destinations, but not necessarily the soure...
    def revtrs_dst2vps(suspected_set, merged_outage)
        symmetric_outages = merged_outage.symmetric_outages
        return if symmetric_outages.empty?

        symmetric_outage.each do |o|
            # select all hops on current traceroutes where source is o.src
            # may have to map from hostname->site
             
        end
    end

    # second half of path splices
    def intersecting_traces_to_src(suspect_set, merged_outage)
        all_hops = []
        merged_outage.each do |o|
            # select all hops on current traceroutes where destination is o.src
             
        end 
        return all_hops
    end
end
