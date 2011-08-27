#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'isolation_module'
require 'drb'
require 'outage_correlation'
require 'failure_analyzer'
require 'outage'

require 'utilities'
Thread.abort_on_exception = true
log = LoggerLog.new($stderr)

analyzer = FailureAnalyzer.new(nil, log)
FailureAnalyzer.load_initializers_and_pruners_from_file(analyzer, FailureIsolation::SuspectSetProcessors)

o = Outage.new
m = MergedOutage.new([o])
analyzer.identify_faults(m)

