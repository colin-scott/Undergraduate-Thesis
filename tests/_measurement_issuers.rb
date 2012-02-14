#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")
$: << File.expand_path("./")

require 'rubygems'
require 'rspec'
require 'unit_test_root'
require 'measurement_issuers'
require 'isolation_utilities'
require 'hops'
require 'set'

RSpec.configure do |config|
  config.mock_framework = :rspec
end

describe "stuff" do
    let(:source) { "toil.cs.washington.edu" }
    let(:ping_receiver) { "crash.cs.washington.edu" }
    let(:trace_receiver) { "riot.cs.washington.edu" }
    let(:test_target) { "74.125.127.106" }
    let(:mock_targets) { [test_target] }
    let(:mock_hosts) { [source,ping_receiver,trace_receiver] }

    let(:mock_ping_results) { ["#{test_target} 52 58 7.992000 32654",source] }
    let(:mock_ping_controller_return) { [mock_ping_results,[],[],[]]  }

    # Output of `hd -C trace.out` to 74.125.127.106
    let(:trace_hex) do
        %{
        00 00 00 00 00 00 00 00 01 00 00 00 a4 00 00 00
        00 00 00 00 00 00 00 00 01 00 00 00 a4 00 00 00
        4a 7d 7f 6a 0d 00 00 00 80 d0 04 66 b6 f3 01 41
        4a 7d 7f 6a 0d 00 00 00 80 d0 04 66 b6 f3 01 41
        ff 00 00 00 cd af 6d 15 5a 64 bb 3e fe 00 00 00
        ff 00 00 00 cd af 6d 15 5a 64 bb 3e fe 00 00 00
        cd af 66 9d 14 ae c7 3e fd 00 00 00 cd af 66 02
        cd af 66 9d 14 ae c7 3e fd 00 00 00 cd af 66 02
        cb c1 25 43 fc 00 00 00 d1 7c be 86 6a bc f4 3e
        cb c1 25 43 fc 00 00 00 d1 7c be 86 6a bc f4 3e
        fa 00 00 00 48 0e df 4e 0c 02 0b 3f f9 00 00 00
        fa 00 00 00 48 0e df 4e 0c 02 0b 3f f9 00 00 00
        48 0e df 4d 25 06 21 3f f8 00 00 00 42 f9 5e d6
        48 0e df 4d 25 06 21 3f f8 00 00 00 42 f9 5e d6
        a0 1a 2f 3f f5 00 00 00 42 f9 5e c5 52 b8 6c 41
        a0 1a 2f 3f f5 00 00 00 42 f9 5e c5 52 b8 6c 41
        f7 01 00 00 d8 ef 2e c8 d3 4d a2 41 f2 01 00 00
        f7 01 00 00 d8 ef 2e c8 d3 4d a2 41 f2 01 00 00
        40 e9 ae 63 5c 8f f2 40 f5 00 00 00 d8 ef 2e 12
        40 e9 ae 63 5c 8f f2 40 f5 00 00 00 d8 ef 2e 12
        62 10 fc 40 f4 00 00 00 4a 7d 7f 6a 2f dd fc 40
        62 10 fc 40 f4 00 00 00 4a 7d 7f 6a 2f dd fc 40
        34 00 00 00 34 00 00 00 
        }.split("\n").join(' ').split 
    end

    # TODO: lower case h?
    let(:trace_binary) { trace_hex.pack("H" * trace_hex.size) }

    # Mock spoofed traceroute
    let(:mock_trace_results) { [[trace_binary,source]] }
    let(:mock_trace_controller_return) { [mock_trace_results,[],[],[]] }

    # For spoofed pings, controller returns  [[probes,receiver],...]
    # probes is [ascii output, sources]
    let(:mock_spoofed_ping_results) { [[["#{test_target} 1 10 0",[source]],ping_receiver]] }
    let(:mock_spoofed_ping_controller_return) { [mock_spoofed_ping_results,[],[],[]] }

    # TTL 1 and 2, spoofer id 0
    let(:mock_spoofed_trace_results) { [[["#{test_target} 0 1 0\n#{test_target} 0 2 0",[source]],trace_receiver]] }
    let(:mock_spoofed_trace_controller_return) { [mock_spoofed_trace_results,[],[],[]] }

    before(:all) do
        class MockController
            def hosts(*args,&block) 
                mock_hosts
            end
            def ping(*args,&block)
                mock_ping_controller_return
            end
            def traceroute(*args,&block)
                mock_trace_controller_return
            end
            # need to differentiate spoofed ping and spoofed tr
            def spoof_tr(srcdst2receivers,&block)
                if srcdst2receivers.values.include? ping_receiver
                    return mock_spoofed_ping_controller_return
                else
                    return mock_spoofed_trace_controller_return
                end
            end
        end

        #mock_controller = double('mock_controller')
        #mock_controller.stub(:hosts) { mock_hosts }
        #mock_controller.stub(:ping) { mock_ping_controller_return }
        #mock_controller.stub(:traceroute) { mock_trace_controller_return }
        ## need to differentiate spoofed ping and spoofed tr
        #mock_controller.stub(:spoof_tr) do |srcdst2receivers|
        #    if srcdst2receivers.values.include? ping_receiver
        #        return mock_spoofed_ping_controller_return
        #    else
        #        return mock_spoofed_trace_controller_return
        #    end
        #end

        ProbeController::set_server(:controller,MockController.new)
    end

    describe Issuers do
        describe Issuers::PingIssuer do
            context "#issue" do
                it "returns a set of responsive target ips" do
                    d = double('foo')
                    p = Issuers::PingIssuer.new
                    p.issue(source,mock_targets).should eq(Set.new(mock_targets))
                end
            end
        end
    
        describe Issuers::SpoofedPingIssuer do
            context "#issue" do
                it "returns a hash target2receiver2succesfulsenders" do
                    s = Issuers::SpoofedPingIssuer.new
                    srcdst2receivers = { [source,test_target] => [ping_receiver] }
                    target2receiver2succesfulsenders = s.issue(srcdst2receivers)
                    target2receiver2succesfulsenders.should_not be_empty
                    # ...
                end
            end
        end
    
        describe Issuers::TraceIssuer do
            context "#issue" do
                it "returns a hash dst2path" do
                    t = Issuers::TraceIssuer.new(TestVars.Logger,TestVars.IpInfo)
                    dst2path = t.issue(source,mock_targets)
                    dst2path.size.should eq(1)
                    dst, path = dst2path.first
                    dst.should eq(test_target)
                    path.should_not be_empty
                end
            end
        end
    
        describe Issuers::SpoofedTraceIssuer do
            context "#issue" do
                it "returns a hash srcdst2path" do
                    s = Issuers::SpoofedTraceIssuer.new(TestVars.Logger,TestVars.IpInfo)
                    srcdst2receivers = { [source,test_target] => [trace_receiver] }
                    target2receiver2succesfulsenders = s.issue(srcdst2receivers)
                    target2receiver2succesfulsenders.should_not be_empty
                    # ...
                end
            end
        end
    end
    
    describe Parsers do
        describe Parsers::PingParser do
            context "#parse" do
                it "returns a set of responsive target ips" do
                    p = Parsers::PingParser.new
                    p.parse(mock_ping_results).should eq(Set.new(mock_targets))
                end
            end
        end
    
        describe Parsers::SpoofedPingParser do
            context "#parse" do
                it "returns a hash target2receiver2succesfulsenders" do
                    p = Parsers::SpoofedPingParser.new
                    p.parse(mock_spoofed_ping_results).should_not be_empty
                end
            end
        end
    
        describe Parsers::TraceParser do
            context "#parse" do
                it "returns a hash dst2path" do
                    p = Parsers::TraceParser.new(TestVars.Logger,TestVars.IpInfo)
                    dst2path = p.parse(mock_trace_results,source,mock_targets)
                    dst2path.size.should eq(1)  
                    dst, path = dst2path.first
                    dst.should eq(test_target)
                    path.should_not be_empty
                end
            end
        end
    
        #describe Parsers::SpoofedTraceParser do
        #    context "#parse" do
        #        it "returns a hash srcdst2path" do
        #            p = Parsers::SpoofedTraceParser.new(TestVars.Logger,TestVars.IpInfo)
        #            p.parse(mock_spoofed_trace_results).should_not be_empty
        #        end
        #    end
        #end
    end
end
