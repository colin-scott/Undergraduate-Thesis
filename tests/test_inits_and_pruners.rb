#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require 'rspec'
require 'isolation_module'
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

        it "should find historical revtr hops" do 
            historical_revtr_hops = @initializer.historical_revtr_dst2src(Fixture.merged_outage)\
                .sort.uniq
            #$stderr.puts "historical_revtr_hops #{historical_revtr_hops.inspect}"
            #$stderr.puts "Fixture hops #{Fixture.historical_revtr.inspect}"
        end

        it "should gather some revtrs" do
            #$stderr.puts @initializer.historical_revtrs_dst2vps(Fixture.merged_outage)
        end

        it "should gather some trs" do
            #$stderr.puts @initializer.historical_trs_to_src(Fixture.merged_outage)
        end
    end
    
    describe Pruner do
        before(:each) do
            @pruner = Pruner.new(@registrar, @database, @log)
        end

        it "should issue pings" do
           to_remove = @pruner.pings_from_source(Fixture.suspect_set, Fixture.merged_outage)
           to_remove.should_not be_empty
           
           tr_hops = Fixture.merged_outage.first.tr.map { |hop|  hop.ip }.flatten.to_set
           tr_hops ||= []
           responsive_targets =  Fixture.merged_outage.first.responsive_targets
           responsive_targets ||= []

           left = to_remove - tr_hops - responsive_targets
          
           left.should_not be_empty
           #$stderr.puts left.inspect
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
