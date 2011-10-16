#!/homes/network/revtr/ruby/bin/ruby

$: << "/homes/network/revtr/spoofed_traceroute/reverse_traceroute"

require 'failure_isolation_consts'

# Given a timestamp, I want:
#    - the PL-PL traces for that timestamp, for pruning
#    - All historical traces up to that point, for initializing

# I can get the latter just by re-running the historical PLPL Hops

CurrentPLPLTracesPath
