#!/homes/network/revtr/ruby/bin/ruby

# CONSTANTS!!!

require 'set'
$config = "/homes/network/revtr/spoofed_traceroute/spooftr_config.rb"
require $config

# constants for names of datasets (not targets themselves)
module DataSets
    DataSets::HarshaPoPs = :"Harsha's most well-connected PoPs"
    DataSets::BeyondHarshaPoPs = :"Routers on paths beyond Harsha's PoPs"
    DataSets::CloudfrontTargets = :"CloudFront"
    DataSets::SpooferTargets = :"PL/mlab nodes"
    DataSets::Unknown = :"Unknown"

    def self.ToPath(dataset)
        case dataset
        when DataSets::HarshaPoPs
            return FailureIsolation::HarshaPoPsPath
        when DataSets::BeyondHarshaPoPs
            return FailureIsolation::BeyondHarshaPoPsPath
        when DataSets::CloudfrontTargets
            return FailureIsolation::CloudfrontTargetsPath
        when DataSets::SpooferTargets
            return FailureIsolation::SpooferTargetsPath
        when DataSets::Unknown
            return "/dev/null"
        else
            return "/dev/null"
        end
    end
end

# Harsha's Ip2PoP mappings
module PoP
    PoP::Unknown = :"Unknown"
end

module FailureIsolation
    FailureIsolation::DefaultPeriodSeconds = 360

    # out of place...
    FailureIsolation::ControllerUri = IO.read("#{$DATADIR}/uris/controller.txt").chomp
    FailureIsolation::RegistrarUri = IO.read("#{$DATADIR}/uris/registrar.txt").chomp

    FailureIsolation::TargetSetPath = "/homes/network/revtr/spoofed_traceroute/current_target_set.txt"
    FailureIsolation::TargetSet = Set.new
    
    FailureIsolation::TestPing = "128.208.4.49" # crash.cs.washington.edu

    FailureIsolation::PingMonitorState = "~/colin/target_state.yml"
    FailureIsolation::PingMonitorRepo = "#{$DATADIR}/ping_monitoring_state/"

    FailureIsolation::MonitoringNodes = "/homes/network/revtr/spoofed_traceroute/cloudfront_spoofing_monitoring_nodes.txt"

    FailureIsolation::MonitorSlice = "uw_revtr2"
    FailureIsolation::IsolationSlice = "uw_revtr" # why do we separate the slices?

    FailureIsolation::RevtrRequests = "/homes/network/revtr/failure_isolation/revtr_requests/current_requests.txt"

    FailureIsolation::HistoricalTraces = "#{$DATADIR}/most_recent_historical_traces.txt"

    FailureIsolation::CachedRevtrTool = "~/dave/revtr-test/reverse_traceroute/print_cached_reverse_path.rb"

    FailureIsolation::TargetBlacklistPath = "/homes/network/revtr/spoofed_traceroute/target_blacklist.txt"
    FailureIsolation::TargetBlacklist = Set.new

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
            return DataSets::HarshaPoPs
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

        # pops are symbols!
        FailureIsolation::IPToPoPMapping.clear
        FailureIsolation::IPToPoPMapping.merge!(IO.read(FailureIsolation::IPToPoPMappingPath)\
                                                .split("\n").map { |line| line.split }.map { |ippop| [ippop[0], ippop[1].to_sym] }.to_hash)

        FailureIsolation::TargetBlacklist.clear
        FailureIsolation::TargetBlacklist.merge(IO.read(FailureIsolation::TargetBlacklistPath).split("\n"))
        
        FailureIsolation::TargetSet.clear
        FailureIsolation::TargetSet.merge(IO.read(FailureIsolation::TargetSetPath).split("\n"))
    end

    FailureIsolation::AllNodesPath = "/homes/network/revtr/spoofed_traceroute/all_isolation_nodes.txt"
    FailureIsolation::BlackListPath = "/homes/network/revtr/spoofed_traceroute/blacklisted_isolation_nodes.txt"
    FailureIsolation::CurrentNodesPath = "/homes/network/revtr/spoofed_traceroute/cloudfront_spoofing_monitoring_nodes.txt"
    FailureIsolation::ToilNodesPath = "/home/cs/colin/ping_monitoring/cloudfront_monitoring/cloudfront_spoofing_monitoring_nodes.txt"
    FailureIsolation::PingStatePath = "/homes/network/revtr/spoofed_traceroute/data/ping_monitoring_state"
    FailureIsolation::NodeToRemovePath = "/homes/network/revtr/spoofed_traceroute/data/sig_usr2_node_to_remove.txt"
    FailureIsolation::NumActiveNodes = 12

    # =========================
    #   Top Pops Regeneration #
    # =========================
    
    # XXX Too big to store in memory?
    FailureIsolation::IPToPoPMappingPath = "/homes/network/harsha/logs_dir/curr_clustering/curr_ip_to_pop_mapping.txt"
    FailureIsolation::IPToPoPMapping = Hash.new { |h,k| PoP::Unknown }

    FailureIsolation::TopPoPsScripts = "/homes/network/revtr/spoofed_traceroute/harshas_new_targets/generate_N_top_pops.sh"

    # More than actually needed
    FailureIsolation::NumTopPoPs = 200

    # Connectivity ranking for top N PoPs.       Format: <pop #> <number of traversing paths> <max paths from any one VP?> <total VPs>
    FailureIsolation::TopN = "/homes/network/revtr/spoofed_traceroute/harshas_new_targets/top_500.txt"
    # trace.out files for the VPs passing through the top 500 pops. Format: <trace.out> <total # paths> <# paths passing through top 100 pops>. Last line is total overall.
    FailureIsolation::SelectedPaths = "/homes/network/revtr/spoofed_traceroute/harshas_new_targets/selected_paths.txt"
    # PL sources and targets for top 500 PoPs. Format: <pop #> <PL node> <target>
    FailureIsolation::SourceDests = "/homes/network/revtr/spoofed_traceroute/harshas_new_targets/srcdsts.txt"

    FailureIsolation::CoreRtrsPerPoP = 1
    FailureIsolation::EdgeRtrsPerPoP = 2
end

FailureIsolation::ReadInDataSets()
