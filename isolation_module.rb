#!/homes/network/revtr/ruby/bin/ruby

# CONSTANTS!!!

require 'set'
require 'utilities'
require 'yaml'

# TODO: don't load this here... make loaders do it explicity for performance
# reasons
$config = "/homes/network/revtr/spoofed_traceroute/spooftr_config.rb"
require $config

# Constants for the entire isolation system
module FailureIsolation
    # ====================================
    #         miscellaneous              #
    # ====================================
    FailureIsolation::DefaultPeriodSeconds = 360

    FailureIsolation::TestPing = "128.208.4.49" # crash.cs.washington.edu

    FailureIsolation::MonitorSlice = "uw_revtr2"
    FailureIsolation::IsolationSlice = "uw_revtr" # why do we separate the slices?

    FailureIsolation::RevtrRequests = "/homes/network/revtr/failure_isolation/revtr_requests/current_requests.txt"

    # out of place...
    FailureIsolation::ControllerUri = IO.read("#{$DATADIR}/uris/controller.txt").chomp
    FailureIsolation::RegistrarUri = IO.read("#{$DATADIR}/uris/registrar.txt").chomp

    FailureIsolation::CachedRevtrTool = "~revtr/dave/revtr-test/reverse_traceroute/print_cached_reverse_path.rb"

    FailureIsolation::ReadTraces = "~revtr/colin/Scripts/readouttraces"
    FailureIsolation::HopsTowardsSrc = "/homes/network/revtr/colin/Scripts/gather_hops_on_traces_towards_ipsX_input_filesY\*"

    FailureIsolation::HistoricalPLPLHopsPath = "/homes/network/revtr/spoofed_traceroute/data/historical_pl_pl_hops.yml"

    FailureIsolation::CurrentPLPLTracesPath = "/homes/network/ethan/failures/pl_pl_traceroutes/logs/currentlogdir/probes"

    def self.current_hops_on_pl_pl_traces_to_site(site)
        return nil unless FailureIsolation::Site2Hosts.include? site
        all_src_ips = FailureIsolation::Site2Hosts[site].map { |host| FailureIsolation::Host2IP[host] }
        File.open("/tmp/site_hosts.txt", "w") { |f| f.puts all_src_ips.join "\n" }
        Set.new(`#{FailureIsolation::HopsTowardsSrc} /tmp/site_hosts.txt #{FailureIsolation::CurrentPLPLTracesPath}/*`.split("\n"))
    end

    # returns direction2site2hops
    # where direction is one of :source or :destination
    # :source is hops seen sent from the source
    # and :destination is hops seen sent towards the destination
    #
    # pre: FailureIsolation::Host2Site is initialized
    def self.historical_pl_pl_hops
        direction2host2hops = YAML.load_file(FailureIsolation::HistoricalPLPLHopsPath)
        direction2site2hops = Hash.new { |h,k| h[k] = Hash.new { |h1,k1| h1[k1] = [] } }
        direction2host2hops.each do |direction, host2hops|
            host2hops.each do |host, hops|
                direction2site2hops[direction][FailureIsolation::Host2Site[host]] |= hops 
            end
        end
        direction2site2hops
    end

    def FailureIsolation::read_in_ip2hostname()
       # TODO BETTER: read in from the database
       ip2hostname = {}
       File.foreach("#{$DATADIR}/pl_hostnames_w_ips.txt") do |line|
          hostname, ip = line.chomp.split  
          ip2hostname[ip] = hostname
       end
       ip2hostname
    end

    FailureIsolation::IP2Hostname = Hash.new { |h,k| k }
    FailureIsolation::Host2IP = Hash.new { |h,k| k }
    FailureIsolation::Host2Site = Hash.new { |h,k| k }
    FailureIsolation::Site2Hosts = {}
    FailureIsolation::SiteMapper = "/homes/network/ethan/scripts/list_sites_for_pl_hosts_in_fileX.pl"

    # ====================================
    #         Data Directories           #
    # ====================================
    FailureIsolation::IsolationResults = "#{$DATADIR}/isolation_results_final"
    FailureIsolation::MergedIsolationResults = "#{$DATADIR}/merged_isolation_results"
    FailureIsolation::Snapshot = "#{$DATADIR}/isolation_results_snapshot"

    FailureIsolation::OutageCorrelation = "#{$DATADIR}/outage_correlation" 

    FailureIsolation::DotFiles = "#{$DATADIR}/dots"

    FailureIsolation::WebDirectory = "/homes/network/revtr/www/isolation_graphs"

    FailureIsolation::PingMonitorState = "~/colin/target_state.yml"
    FailureIsolation::PingMonitorRepo = "#{$DATADIR}/ping_monitoring_state/"

    FailureIsolation::HistoricalTraces = "#{$DATADIR}/most_recent_historical_traces.txt"

    FailureIsolation::DataSetDir = "/homes/network/revtr/spoofed_traceroute/datasets"

    FailureIsolation::PingStatePath = "/homes/network/revtr/spoofed_traceroute/data/ping_monitoring_state"
    
    # ====================================
    #         Target Sets                #
    # ====================================
    FailureIsolation::TargetSetPath = "/homes/network/revtr/spoofed_traceroute/current_target_set.txt"
    FailureIsolation::TargetSet = Set.new

    FailureIsolation::TargetBlacklistPath = "/homes/network/revtr/spoofed_traceroute/target_blacklist.txt"
    FailureIsolation::TargetBlacklist = Set.new

    # targets taken from Harsha's most well connected PoPs
    FailureIsolation::HarshaPoPsPath = "#{FailureIsolation::DataSetDir}/responsive_corerouters.txt"
    FailureIsolation::HarshaPoPs = Set.new

    # targets taken from routers on paths beyond Harsha's most well connected PoPs
    FailureIsolation::BeyondHarshaPoPsPath = "#{FailureIsolation::DataSetDir}/responsive_edgerouters.txt"
    FailureIsolation::BeyondHarshaPoPs = Set.new

    # For Ethan's PL-PL traceroutes -- <hostname> <ip> <site>
    FailureIsolation::SpooferTargetsMetaDataPath = "#{FailureIsolation::DataSetDir}/up_spoofers_w_sites.txt"
    #  XXX Take in from isolation_vantage_points table instaed of this static list.
    FailureIsolation::SpooferTargetsPath = "#{FailureIsolation::DataSetDir}/up_spoofers.ips"
    FailureIsolation::SpooferTargets = Set.new

    # targets taken from cloudfront ips
    FailureIsolation::CloudfrontTargetsPath = "#{FailureIsolation::DataSetDir}/cloudfront_ips.txt"
    FailureIsolation::CloudfrontTargets = Set.new

    # targets taken from AT&T ips, for potential ground truth
    FailureIsolation::ATTTargetsPath = "/homes/network/revtr/dave/revtr-test/reverse_traceroute/data/att_responsive_just_ips.txt"
    FailureIsolation::ATTTargets = Set.new

    # !!!!!!!!!!!!!!!!!!!
    #   to add a dataset, mimick the above lines

    def FailureIsolation::get_dataset(dst)
        if FailureIsolation::HarshaPoPs.include? dst
            return DataSets::HarshaPoPs
        elsif FailureIsolation::BeyondHarshaPoPs.include? dst
            return DataSets::BeyondHarshaPoPs 
        elsif FailureIsolation::CloudfrontTargets.include? dst
            return DataSets::CloudfrontTargets
        elsif FailureIsolation::SpooferTargets.include? dst
            return DataSets::SpooferTargets
        elsif FailureIsolation::ATTTargets.include? dst
            return DataSets::ATTTargets
        else
            return DataSets::Unknown 
        end
    end

    def FailureIsolation::ReadInDataSets()
        FailureIsolation::Host2Site.clear
        FailureIsolation::Host2Site.merge!(`#{FailureIsolation::SiteMapper} #{$DATADIR}/pl_hostnames_w_ips.txt | cut -d ' ' -f1,3`\
                                          .split("\n").map { |line| line.split }.to_hash)

        FailureIsolation::Site2Hosts.clear
        FailureIsolation::Site2Hosts.merge!(FailureIsolation::Host2Site.value2keys)

        FailureIsolation::IP2Hostname.clear
        FailureIsolation::IP2Hostname.merge!(FailureIsolation::read_in_ip2hostname)

        FailureIsolation::Host2IP.clear
        FailureIsolation::Host2IP.merge!(FailureIsolation::IP2Hostname.invert)
        
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

        FailureIsolation::ATTTargets.clear
        FailureIsolation::ATTTargets.merge(IO.read(FailureIsolation::ATTTargetsPath).split("\n"))

        FailureIsolation::UpdateTargetSet()
    end

    def FailureIsolation::UpdateTargetSet()
        FailureIsolation::TargetSet.clear
        union = DataSets::AllDataSets.reduce(Set.new) { |sum,arr| sum | arr }
        FailureIsolation::TargetSet.merge(union)
        File.open(FailureIsolation::TargetSetPath, "w") { |f| f.puts FailureIsolation::TargetSet.to_a.join "\n" }
    end

    # ====================================
    #         Vantage Points             #
    # ====================================

    FailureIsolation::NumActiveNodes = 13

    FailureIsolation::AllNodesPath = "/homes/network/revtr/spoofed_traceroute/all_isolation_nodes.txt"
    FailureIsolation::AllNodes = Set.new

    FailureIsolation::NodeBlacklistPath = "/homes/network/revtr/spoofed_traceroute/blacklisted_isolation_nodes.txt"
    FailureIsolation::NodeBlacklist = Set.new

    FailureIsolation::CurrentNodesPath = "/homes/network/revtr/spoofed_traceroute/cloudfront_spoofing_monitoring_nodes.txt"
    FailureIsolation::CurrentNodes = Set.new

    FailureIsolation::ToilNodesPath = "/home/cs/colin/ping_monitoring/cloudfront_monitoring/cloudfront_spoofing_monitoring_nodes.txt"

    FailureIsolation::NodeToRemovePath = "/homes/network/revtr/spoofed_traceroute/data/sig_usr2_node_to_remove.txt"

    def FailureIsolation::ReadInNodeSets()
        FailureIsolation::AllNodes.clear
        FailureIsolation::AllNodes.merge(IO.read(FailureIsolation::AllNodesPath).split("\n"))

        FailureIsolation::NodeBlacklist.clear
        FailureIsolation::NodeBlacklist.merge(IO.read(FailureIsolation::NodeBlacklistPath).split("\n"))

        FailureIsolation::CurrentNodes.clear
        FailureIsolation::CurrentNodes.merge(IO.read(FailureIsolation::CurrentNodesPath).split("\n"))
    end

    # =========================
    #   Top Pops Regeneration #
    # =========================
    
    # More than actually needed
    FailureIsolation::NumTopPoPs = 200

    FailureIsolation::CoreRtrsPerPoP = 1
    FailureIsolation::EdgeRtrsPerPoP = 2

    # TODO: Too big to store in memory?
    FailureIsolation::IPToPoPMappingPath = "/homes/network/harsha/logs_dir/curr_clustering/curr_ip_to_pop_mapping.txt"
    FailureIsolation::IPToPoPMapping = Hash.new { |h,k| PoP::Unknown }

    FailureIsolation::TopPoPsScripts = "/homes/network/revtr/spoofed_traceroute/harshas_new_targets/generate_N_top_pops.sh"

    # Connectivity ranking for top N PoPs.       Format: <pop #> <number of traversing paths> <max paths from any one VP?> <total VPs>
    FailureIsolation::TopN = "/homes/network/revtr/spoofed_traceroute/harshas_new_targets/top_500.txt"
    # trace.out files for the VPs passing through the top 500 pops. Format: <trace.out> <total # paths> <# paths passing through top 100 pops>. Last line is total overall.
    FailureIsolation::SelectedPaths = "/homes/network/revtr/spoofed_traceroute/harshas_new_targets/selected_paths.txt"
    # PL sources and targets for top 500 PoPs. Format: <pop #> <PL node> <target>
    FailureIsolation::SourceDests = "/homes/network/revtr/spoofed_traceroute/harshas_new_targets/srcdsts.txt"
end

# constants for names of datasets (not targets themselves)
module DataSets
    DataSets::HarshaPoPs = :"Harsha's most well-connected PoPs"
    DataSets::BeyondHarshaPoPs = :"Routers on paths beyond Harsha's PoPs"
    DataSets::CloudfrontTargets = :"CloudFront"
    DataSets::SpooferTargets = :"PL/mlab nodes"
    DataSets::Unknown = :"Unknown"
    DataSets::ATTTargets = :"ATT"

    # !!!!!!!!!!!!!!!
    #  to add a dataset, add an element to this array, and edit
    #  the path in FailureIsolation. Note that these are the Sets! not the
    #  symbols
    DataSets::AllDataSets = [FailureIsolation::HarshaPoPs, FailureIsolation::BeyondHarshaPoPs,
        FailureIsolation::CloudfrontTargets, FailureIsolation::SpooferTargets,FailureIsolation::ATTTargets]

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
        when DataSets::ATTTargets
            return FailureIsolation::ATTTargetsPath
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

FailureIsolation::ReadInDataSets()
FailureIsolation::ReadInNodeSets()

if $0 == __FILE__
    #puts FailureIsolation::Site2Hosts.inspect
    #puts FailureIsolation::Host2Site.inspect
    puts FailureIsolation.current_hops_on_pl_pl_traces_to_site("arizona-gigapop.net").to_a.inspect
end
