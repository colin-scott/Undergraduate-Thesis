#!/homes/network/revtr/ruby-upgrade/bin/ruby

require_relative 'unit_test_root'
require_relative '../failure_monitor'

describe FailureMonitor do
    let(:node2targetstate) { TestVars.Monitor.read_in_results } 
    let(:target2observingnode2rounds) { TestVars.Monitor.classify_outages(node2targetstate)[0] }
    let(:target2neverseen) { TestVars.Monitor.classify_outages(node2targetstate)[1] }
    let(:target2stillconnected) { TestVars.Monitor.classify_outages(node2targetstate)[2] }
    
    describe("#filter_outages") do
        it "returns same # of outages as passed filters" do
            puts node2targetstate.inspect
            srcdst2outage, srcdst2filtertracker = TestVars.Monitor.filter_outages(
                                target2observingnode2rounds, target2neverseen, target2stillconnected)
    
            total_passed_filters = srcdst2filtertracker.values.find_all { |tracker| tracker.passed? }.size
            total_passed_filters.should eq(srcdst2outage.size)
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
