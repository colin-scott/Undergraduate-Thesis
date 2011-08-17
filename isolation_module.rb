# CONSTANTS!!!

require 'set'
$config = "/homes/network/revtr/spoofed_traceroute/spooftr_config.rb"
require $config

module FailureIsolation
    FailureIsolation::DefaultPeriodSeconds = 360

    # out of place...
    FailureIsolation::ControllerUri = IO.read("#{$DATADIR}/uris/controller.txt").chomp
    FailureIsolation::RegistrarUri = IO.read("#{$DATADIR}/uris/registrar.txt").chomp

    # XXX terrible terrible
    FailureIsolation::CloudfrontTargets = Set.new([ "204.246.165.221", "204.246.169.63", "216.137.33.1",
        "216.137.35.21", "216.137.37.156", "216.137.39.152", "216.137.41.78",
        "216.137.43.189", "216.137.45.33", "216.137.47.127", "216.137.53.96",
        "216.137.55.170", "216.137.57.207", "216.137.59.4", "216.137.61.174",
        "216.137.63.221" ])

    FailureIsolation::TargetSet = "/homes/network/revtr/spoofed_traceroute/current_target_set.txt"
    
    FailureIsolation::TestPing = "128.208.4.49" # crash.cs.washington.edu

    FailureIsolation::PingMonitorState = "~/colin/target_state.yml"
    FailureIsolation::PingMonitorRepo = "#{$DATADIR}/ping_monitoring_state/"

    FailureIsolation::MonitoringNodes = "/homes/network/revtr/spoofed_traceroute/cloudfront_spoofing_monitoring_nodes.txt"

    FailureIsolation::MonitorSlice = "uw_revtr2"
    FailureIsolation::IsolationSlice = "uw_revtr" # why do we separate the slices?

    FailureIsolation::RevtrRequests = "/homes/network/revtr/failure_isolation/revtr_requests/current_requests.txt"

    FailureIsolation::HistoricalTraces = "#{$DATADIR}/most_recent_historical_traces.txt"

    FailureIsolation::CachedRevtrTool = "~/dave/revtr-test/reverse_traceroute/print_cached_reverse_path.rb"

    FailureIsolation::TargetBlacklist = "/homes/network/revtr/spoofed_traceroute/target_blacklist.txt"

    def FailureIsolation::read_in_spoofer_hostnames()
       ip2hostname = {}
       File.foreach("#{$DATADIR}/up_spoofers_w_ips.txt") do |line|
          hostname, ip = line.chomp.split  
          ip2hostname[ip] = hostname
       end
       ip2hostname
    end

    FailureIsolation::DataSetDir = "/homes/network/revtr/spoofed_traceroute/datasets"
    # targets taken from Harsha's most well connected PoPs
    FailureIsolation::HarshaPoPs = Set.new(IO.read("#{FailureIsolation::DataSetDir}/responsive_corerouters.txt").split("\n"))
    # targets taken from routers on paths beyond Harsha's most well connected PoPs
    FailureIsolation::BeyondHarshaPoPs = Set.new(IO.read("#{FailureIsolation::DataSetDir}/responsive_edgerouters.txt").split("\n"))
    # targets taken from spoofers.hosts
    FailureIsolation::SpooferTargets = Set.new(IO.read("#{FailureIsolation::DataSetDir}/up_spoofers.ips").split("\n"))
    FailureIsolation::SpooferIP2Hostname = FailureIsolation::read_in_spoofer_hostnames


    FailureIsolation::IsolationResults = "#{$DATADIR}/isolation_results_final"
    FailureIsolation::Snapshot = "#{$DATADIR}/isolation_results_snapshot"

    FailureIsolation::OutageCorrelation = "#{$DATADIR}/outage_correlation" 

    FailureIsolation::DotFiles = "#{$DATADIR}/dots"

    FailureIsolation::WebDirectory = "/homes/network/revtr/www/isolation_graphs"

    def FailureIsolation::get_dataset(dst)
        if FailureIsolation::HarshaPoPs.include? dst
            return "Harsha's most well-connected PoPs"
        elsif FailureIsolation::BeyondHarshaPoPs.include? dst
            return "Routers on paths beyond Harsha's PoPs"
        elsif FailureIsolation::CloudfrontTargets.include? dst
            return "CloudFront"
        elsif FailureIsolation::SpooferTargets.include? dst
            return "PL/mlab nodes"
        else
            return "Unknown"
        end
    end

    FailureIsolation::AllNodesPath = "/homes/network/revtr/spoofed_traceroute/all_isolation_nodes.txt"
    FailureIsolation::BlackListPath = "/homes/network/revtr/spoofed_traceroute/blacklisted_isolation_nodes.txt"
    FailureIsolation::CurrentNodesPath = "/homes/network/revtr/spoofed_traceroute/cloudfront_spoofing_monitoring_nodes.txt"
    FailureIsolation::ToilNodesPath = "/home/cs/colin/ping_monitoring/cloudfront_monitoring/cloudfront_spoofing_monitoring_nodes.txt"
    FailureIsolation::PingStatePath = "/homes/network/revtr/spoofed_traceroute/data/ping_monitoring_state"
    FailureIsolation::NodeToRemovePath = "/homes/network/revtr/spoofed_traceroute/data/sig_usr2_node_to_remove.txt"
    FailureIsolation::NumActiveNodes = 12
end
