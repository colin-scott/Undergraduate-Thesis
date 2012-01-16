#!/homes/network/revtr/ruby-upgrade/bin/ruby

require_relative 'unit_test_root'
require_relative '../failure_monitor'

describe FailureMonitor do
    let(:node2targetstate) { TestVars.Monitor.read_in_results(Time.parse("2012.01.05 02:56:34") + Time.new.utc_offset) } 
    let(:target2observingnode2rounds) { TestVars.Monitor.classify_outages(node2targetstate)[0] }
    let(:target2neverseen) { TestVars.Monitor.classify_outages(node2targetstate)[1] }
    let(:target2stillconnected) { TestVars.Monitor.classify_outages(node2targetstate)[2] }

    describe("#read_in_results") do
        it "returns non-empty results" do
            node2targetstate.should_not be_empty
        end
    end

    describe("#parse_filename") do
        it "does not throw an exception" do
            TestVars.Monitor.parse_filename("/foo/bar/ping_monitoring_state/dschinni.planetlab.extranet.uni-passau.de++2012.01.05.02.56.50.yml")
        end
    end
    
    describe("#filter_outages") do
        it "returns same # of outages as passed filters" do
            srcdst2outage, srcdst2filtertracker = TestVars.Monitor.filter_outages(
                                target2observingnode2rounds, target2neverseen, target2stillconnected)
    
            total_passed_filters = srcdst2filtertracker.values.find_all { |tracker| tracker.passed? }.size
            total_passed_filters.should eq(srcdst2outage.size)
        end
    end

    describe("#parse_filename") do 
        it "recovers from target_state.yml input" do
            input = "/homes/network/revtr/spoofed_traceroute/data/ping_monitoring_state/target_state.yml"
            #Object.any_instance.stub(:`)
            #Object.any_instance.stub(:system)
            TestVars.Monitor.parse_filename(input)
        end
    end
end

# TODO: turn this into a real unit test rather than printing out stdout

# TODO: Don't want to have to load this
#require 'isolation_module' 
#require 'failure_TestVarsgcMonitor'
#
#TestVarsgcMonitor = FailureTestVars::Monitor.new
#
#outage_state = { "1.2.3.4" => 20 }
#connected_state = {}
#node2targetstate = { "froo.froo" => outage_state, 
#                     "frooz.frooz" => outage_state, 
#                     "fram.fram" => connected_state }
#
#target2observingnode2rounds, target2neverseen, target2stillconnected = TestVarsgcMonitor.classify_outages(node2targetstate)
#$stderr.puts "target2observingnode2rounds #{target2observingnode2rounds}"
#$stderr.puts "target2neverseen #{target2neverseen}" 
#$stderr.puts "target2stillconnected #{target2stillconnected}"
#
#srcdst2outage, dst2filter_tracker = TestVarsgcMonitor.filter_outages(target2observingnode2rounds, target2neverseen, target2stillconnected)
#
#$stderr.puts "srcdst2outage #{srcdst2outage}"
#$stderr.puts "dst2filter_tracker #{dst2filter_tracker}"
#
## TODO: assert that output matches expected
