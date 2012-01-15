#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require File::expand_path(File::dirname(__FILE__)) + '/unit_test_root'
require 'direction'
require 'poisoner'

describe Poisoner do
    before(:each) do
        @p = Poisoner.new
        # Don't actually poison
        @p.stub(:execute_poison)
        # Don't actually log (yet)
        @p.stub(:log_outages)

        @outage1 = Marshal.load(IO.read("fixtures/mlab1.ath01.measurement-lab.org_193.138.215.1_20110921081833.bin"))
        @outage2 = Marshal.load(IO.read("fixtures/mlab1.ath01.measurement-lab.org_193.200.159.1_20110921081829.bin"))
        @outage1.src = "prin.bgpmux"
        @outage2.src = "UWAS.BGPMUX"
        
        @outage1.direction = Direction.REVERSE
        @outage2.direction = Direction.BOTH
        
        @outage1.complete_reverse_isolation = true
        
        @outage1.passed_filters = true
        @outage2.passed_filters = true
        
        @outage1.suspected_failures[Direction.REVERSE] = [Hop.new("218.101.61.52", TestVars.IpInfo)]
        @outage2.suspected_failures[Direction.FORWARD] = [Hop.new("218.101.61.52", TestVars.IpInfo)]
        
        @merged_outage = MergedOutage.new([@outage1, @outage2])
    end

    describe "#check_poisonability" do
        it "should poison reverse path outages" do
            @p.should_receive(:execute_poison)

            @p.check_poisonability(@merged_outage)
        end

        it "should skip forward path outages" do
            @p.should_not_receive(:execute_poison)
             
            @outage1.direction = Direction.FORWARD
            @outage2.direction = Direction.FORWARD

            @p.check_poisonability(@merged_outage)
        end
    end

    describe "#log_outages" do
        it "should log one outage properly" do
            @p.unstub(:log_outages)

            @p.log_outages({"mlab"=>{Direction.REVERSE=>{@outage1=>@outage1.suspected_failures[Direction.REVERSE]}}})
            puts IO.read(TestVars::PoisonLogPath)
        end
    end
end
