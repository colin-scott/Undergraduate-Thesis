#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

#require 'rspec'
require 'isolation_module'
#require 'drb'
require 'outage_correlation'
require 'failure_analyzer'
require 'outage'
require 'suspect_set_processors'
require 'db_interface'
require 'utilities'
Thread.abort_on_exception = true

#describe "identify_failures" do
#    before(:each) do
#        @controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
#        @registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)
#        @database = DatabaseInterface.new
#        @log = LoggerLog.new($stderr)
#        @analyzer = FailureAnalyzer.new(IpInfo.new, @log, @registrar, @database)
#        @outage1 = Marshal.load(IO.read("mlab1.ath01.measurement-lab.org_193.138.215.1_20110921081833.bin"))
#        @outage2 = Marshal.load(IO.read("mlab1.ath01.measurement-lab.org_193.200.159.1_20110921081829.bin"))
#
#        @merged_outage = MergedOutage.new([@outage1, @outage2])
#    end
#
#    it "should"
#end

class MockRegistrar
    def all_pairs_ping(srcs, dsts)
        {}
    end
end

@database = DatabaseInterface.new
@log = LoggerLog.new($stderr)
@analyzer = FailureAnalyzer.new(IpInfo.new, @log, MockRegistrar.new, @database)
@outage1 = Marshal.load(IO.read("mlab1.ath01.measurement-lab.org_193.138.215.1_20110921081833.bin"))
@outage2 = Marshal.load(IO.read("mlab1.ath01.measurement-lab.org_193.200.159.1_20110921081829.bin"))
@merged_outage = MergedOutage.new([@outage1, @outage2])

@analyzer.identify_faults(@merged_outage)
$stderr.puts @merged_outage.initializer2suspectset.map_values { |v| v.to_a.map { |s| s.ip }.uniq.size }.inspect
$stderr.puts @merged_outage.initializer2suspectset.value_set.to_a.map { |s| s.ip }.uniq.size
$stderr.puts @merged_outage.pruner2incount_removed.map_values { |v| [v[0], v[1].size] }.inspect
$stderr.puts @merged_outage.suspected_failures[Direction.REVERSE].size
