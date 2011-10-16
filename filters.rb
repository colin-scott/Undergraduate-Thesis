
module FirstLevelFilters
    UPPER_ROUNDS_BOUND = 500
    LOWER_ROUNDS_BOUND = 4
    VP_BOUND = 1
    
    # (at least one VP has connectivity)
    def no_vp_has_connectivity?(stillconnected)
        stillconnected.size < VP_BOUND
    end

    # (don't issue from nodes that have been experiencing the outage for a very long time)
    def no_vp_newly_observed?(observingnode2rounds)
       observingnode2rounds.delete_if { |node, rounds| rounds >= UPPER_ROUNDS_BOUND }.size < VP_BOUND
    end

    # (don't issue from nodes that just started seeing the outage)
    def no_stable_unconnected_vp?(observingnode2rounds)
         observingnode2rounds.delete_if { |node, rounds| rounds < LOWER_ROUNDS_BOUND }.size < VP_BOUND
    end

    # (at least one connected host has been consistently connected for at least 4 rounds)
    def no_stable_connected_vp?(stillconnected, nodetarget2lastoutage, target, now)
       stillconnected.find { |node| (now - (nodetarget2lastoutage[[node, target]] or Time.at(0))) / 60 > LOWER_ROUNDS_BOUND }.nil?
    end

    # (if a poisoner is observing, make sure at least on other non-poinonser is also observing)
    def no_non_poisoner?(nodes)
       # if at least one poisoner, make sure at least one non-poisoner
       (nodes.find { |n| FailureIsolation::PoisonerNames.include? n }) ? nodes.find { |n| !FailureIsolation::PoisonerNames.include? n } : false
    end

    # (at least one observing node remains)
    def no_vp_remains?(observingnode2rounds)
       observingnode2rounds.empty? 
    end
end

# Filters out nodes that aren't registered with the controller, 
#
# TODO: class methods or instance methods?
module RegistrationFilters
    SRC_NOT_REGISTERED = :source_not_registered 
    NO_REGISTERED_RECEIVERS = :no_receivers_registered

    def self.src_not_registered?(src, registered_vps)
        !(registered_vps.include?(src))
    end

    def self.no_registered_receivers?(receivers, registered_vps)
        (receivers & registered_vps).empty?
    end
end


# TODO: move failure_analyzer#passes_filters? here
module SecondLevelFilters

end
