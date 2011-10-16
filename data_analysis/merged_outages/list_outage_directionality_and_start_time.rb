#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../../")

require 'isolation_module'
require 'failure_isolation_consts.rb'
require 'failure_analyzer'
require 'failure_dispatcher'
require 'log_iterator'
require 'ip_info'
require 'set'
require 'yaml'
require 'time'

src_time_directions = []

start_date = Time.utc(2011, 8, 25)

not_nil_count = 0

LogIterator::merged_iterate do |o|
    next unless o.is_interesting?
    not_nil_count += 1 

    $stderr.puts o.suspected_failures.inspect
end

puts not_nil_count
