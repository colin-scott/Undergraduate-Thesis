#!/homes/network/revtr/ruby/bin/ruby

# CONSTANTS!!!

require 'set'
$config = "/homes/network/revtr/spoofed_traceroute/spooftr_config.rb"
require $config

module FailureIsolation
    FailureIsolation::DefaultPeriodSeconds = 360

    # out of place...
    FailureIsolation::ControllerUri = IO.read("#{$DATADIR}/uris/controller.txt").chomp
    FailureIsolation::RegistrarUri = IO.read("#{$DATADIR}/uris/registrar.txt").chomp


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
    FailureIsolation::HarshaPoPsPath = "#{FailureIsolation::DataSetDir}/responsive_corerouters.txt"
    FailureIsolation::HarshaPoPs = Set.new

    # targets taken from routers on paths beyond Harsha's most well connected PoPs
    FailureIsolation::BeyondHarshaPoPsPath = "#{FailureIsolation::DataSetDir}/responsive_edgerouters.txt"
    FailureIsolation::BeyondHarshaPoPs = Set.new

    # targets taken from spoofers.hosts
    #  XXX Take in from isolation_vantage_points table instaed of this static
    #  list.
    FailureIsolation::SpooferTargetsPath = "#{FailureIsolation::DataSetDir}/up_spoofers.ips"
    FailureIsolation::SpooferTargets = Set.new

    # targets taken from cloudfront ips
    FailureIsolation::CloudfrontTargetsPath = "#{FailureIsolation::DataSetDir}/cloudfront_ips.txt"
    FailureIsolation::CloudfrontTargets = Set.new

    FailureIsolation::SpooferIP2Hostname = FailureIsolation::read_in_spoofer_hostnames

    FailureIsolation::IsolationResults = "#{$DATADIR}/isolation_results_final"
    FailureIsolation::Snapshot = "#{$DATADIR}/isolation_results_snapshot"

    FailureIsolation::OutageCorrelation = "#{$DATADIR}/outage_correlation" 

    FailureIsolation::DotFiles = "#{$DATADIR}/dots"

    FailureIsolation::WebDirectory = "/homes/network/revtr/www/isolation_graphs"

    def FailureIsolation::get_dataset(dst)
        if FailureIsolation::HarshaPoPs.include? dst
            return DataSets::HarshaPops
        elsif FailureIsolation::BeyondHarshaPoPs.include? dst
            return DataSets::BeyondHarshaPoPs 
        elsif FailureIsolation::CloudfrontTargets.include? dst
            return DataSets::CloudfrontTargets
        elsif FailureIsolation::SpooferTargets.include? dst
            return DataSets::SpooferTargets
        else
            return DataSets::Unknown 
        end
    end

    def FailureIsolation::ReadInDataSets()
        FailureIsolation::HarshaPoPs.clear
        FailureIsolation::HarshaPoPs.merge(IO.read(FailureIsolation::HarshaPoPsPath).split("\n"))

        FailureIsolation::BeyondHarshaPoPs.clear
        FailureIsolation::BeyondHarshaPoPs.merge(IO.read(FailureIsolation::BeyondHarshaPoPsPath).split("\n"))

        FailureIsolation::SpooferTargets.clear
        FailureIsolation::SpooferTargets.merge(IO.read(FailureIsolation::SpooferTargetsPath).split("\n"))

        FailureIsolation::CloudfrontTargets.clear
        FailureIsolation::CloudfrontTargets.merge(IO.read(FailureIsolation::CloudfrontTargetsPath).split("\n"))
    end

    FailureIsolation::AllNodesPath = "/homes/network/revtr/spoofed_traceroute/all_isolation_nodes.txt"
    FailureIsolation::BlackListPath = "/homes/network/revtr/spoofed_traceroute/blacklisted_isolation_nodes.txt"
    FailureIsolation::CurrentNodesPath = "/homes/network/revtr/spoofed_traceroute/cloudfront_spoofing_monitoring_nodes.txt"
    FailureIsolation::ToilNodesPath = "/home/cs/colin/ping_monitoring/cloudfront_monitoring/cloudfront_spoofing_monitoring_nodes.txt"
    FailureIsolation::PingStatePath = "/homes/network/revtr/spoofed_traceroute/data/ping_monitoring_state"
    FailureIsolation::NodeToRemovePath = "/homes/network/revtr/spoofed_traceroute/data/sig_usr2_node_to_remove.txt"
    FailureIsolation::NumActiveNodes = 12

    FailureIsolation::IPToPoPMapping = "/homes/network/harsha/logs_dir/curr_clustering/curr_ip_to_pop_mapping.txt"
end

# constants for names of datasets (not targets themselves)
module DataSets
    DataSets::HarshaPops = "Harsha's most well-connected PoPs"
    DataSets::BeyondHarshaPoPs = "Routers on paths beyond Harsha's PoPs"
    DataSets::CloudfrontTargets = "CloudFront"
    DataSets::SpooferTargets = "PL/mlab nodes"
    DataSets::Unknown = "Unknown"
end


FailureIsolation::ReadInDataSets()
