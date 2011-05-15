#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'isolation_module'
require 'hops'

# TODO: encapsulate all of these data items into a single object!
LogIterator::read_log_rev4(FailureIsolation::IsolationResults+"/planetlab-2.sjtu.edu.cn_88.255.65.219_201147155140.yml") do  |outage|
    puts outage
end

