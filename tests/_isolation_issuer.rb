#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require 'rspec'
require 'isolation_issuer'

describe MeasurementRequestor do
    @m = MeasurementRequestor.new

    context "#check_reachability!" do
        it "returns [responsive_hops,unresponsive_hops]" do
            o = Marshal.load(IO.read("fixtures/mlab1.ath01.measurement-lab.org_193.138.215.1_20110921081833.bin"))
            responsive_hops, unresponsive_hops = @m.check_reachability!(o)
            
            responsive_hops.should be_empty
            unresponsive_hops.should_not be_empty
        end
    end

    context "#issue_normal_traceroutes" do
        it "returns a hash dst2path" do
            dst2path = @m.issue_normal_traceroutes(source,test_targets)
            dst2path.size.should eq(1)
            dst, path = dst2path.first
            dst.should eq(test_target)
            path.should_not be_empty
        end
    end

    # TODO: all the other methods
end
