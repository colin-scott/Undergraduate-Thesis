#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'hops'
require 'failure_analyzer'
require 'ip_info'

analyzer = FailureAnalyzer.new(IpInfo.new)


LogIterator::iterate do  |o|
    next unless o.passed_filters
    category = analyzer.categorize_failure(o)
    puts o.file
    puts category 
end
