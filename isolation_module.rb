#!/homes/network/revtr/ruby/bin/ruby

# TODO: don't load this here... make loaders do it explicity for performance
# reasons
$config = "/homes/network/revtr/spoofed_traceroute/spooftr_config.rb"
require $config

require 'failure_isolation_consts'
