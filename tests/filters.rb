#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << "../"

require_relative 'unit_test'
require 'filters.rb'

observing = ["planetlab-1.cs.auckland.ac.nz"]


puts FirstLevelFilters.no_non_poisoner_observing?(observing)

