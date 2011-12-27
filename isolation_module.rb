#!/homes/network/revtr/ruby-upgrade/bin/ruby

# This used to be where all constants for the isolation were stored. It was
# taking too long to load this module, so I separated out $config from lazily
# evaluated datasets in failure_isolation_consts.rb
#
# TODO: don't load this here... make loaders do it explicity for performance
# reasons
$config = "/homes/network/revtr/spoofed_traceroute/spooftr_config.rb"
require $config

require 'failure_isolation_consts'
