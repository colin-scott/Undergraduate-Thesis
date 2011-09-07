#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'rspec'
require 'failure_isolation_consts'
require 'drb'
require 'outage_correlation'
require 'failure_analyzer'
require 'outage'
require 'suspect_set_processors'
require 'db_interface'
require 'fixtures'
require 'utilities'
Thread.abort_on_exception = true

describe "suspect set processors" do
    before(:each) do
        @controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
        @registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)
        @database = DatabaseInterface.new
        @log = LoggerLog.new($stderr)
    end

    describe Initializer do
        before(:each) do
            @initializer = Initializer.new(@registrar, @database, @log)
        end

        it "should respond to methods" do
            @initializer.should respond_to(:inspect)
        end

    end
    
    describe Pruner do
        before(:each) do
            @pruner = Pruner.new(@registrar, @database, @log)
        end
    end
end

#initer = Initializer.new(registrar,database,log)
#pruner = Pruner.new(registrar, database, log)
#
#initer.historical_revtr_dst2src(Fixture.merged_outage)
#
#initer.historical_revtrs_dst2vps(Fixture.merged_outage)
#initer.historical_trs_to_src(Fixture.merged_outage)
#
#pruner.pings_from_source(Fixture.suspect_set, Fixture.merged_outage)
#pruner.intersecting_traces_to_src(Fixture.suspect_set, Fixture.merged_outage)
