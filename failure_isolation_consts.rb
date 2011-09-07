#!/homes/network/revtr/ruby/bin/ruby

# CONSTANTS!!!

require 'set'
require 'utilities'
require 'yaml'

$REV_TR_TOOL_DIR ||= "/homes/network/revtr/spoofed_traceroute/reverse_traceroute"
$DATADIR ||= "/homes/network/revtr/spoofed_traceroute/data"

# XXX Don't hardcode!!!
$pptasks = "~ethan/scripts/pptasks"
$node_to_remove = "/homes/network/revtr/spoofed_traceroute/data/sig_usr2_node_to_remove.txt"

# Constants for the entire isolation system
module FailureIsolation
    # ====================================
    #         miscellaneous              #
    # ====================================
    DefaultPeriodSeconds = 360

    TestPing = "128.208.4.49" # crash.cs.washington.edu

    MonitorSlice = "uw_revtr2"
    IsolationSlice = "uw_revtr" # why do we separate the slices?

    RevtrRequests = "/homes/network/revtr/failure_isolation/revtr_requests/current_requests.txt"

    # out of place...
    ControllerUri = IO.read("#{$DATADIR}/uris/controller.txt").chomp
    RegistrarUri = IO.read("#{$DATADIR}/uris/registrar.txt").chomp

    CachedRevtrTool = "~revtr/dave/revtr-test/reverse_traceroute/print_cached_reverse_path.rb"

    ReadTraces = "~revtr/colin/Scripts/readouttraces"
    HopsTowardsSrc = "/homes/network/revtr/colin/Scripts/gather_hops_on_traces_towards_ipsX_input_filesY\*"

    HistoricalPLPLHopsPath = "/homes/network/revtr/spoofed_traceroute/data/historical_pl_pl_hops.yml"

    CurrentPLPLTracesPath = "/homes/network/ethan/failures/pl_pl_traceroutes/logs/currentlogdir/probes"

    # MOVE ME
    def self.current_hops_on_pl_pl_traces_to_site(db, site)
        return nil unless self.Site2Hosts.include? site
        all_src_ips = self.Site2Hosts[site].map { |host| db.hostname2ip[host] }
        File.open("/tmp/site_hosts.txt", "w") { |f| f.puts all_src_ips.join "\n" }
        Set.new(`#{HopsTowardsSrc} /tmp/site_hosts.txt #{CurrentPLPLTracesPath}/*`.split("\n"))
    end

    # returns direction2site2hops
    # where direction is one of :source or :destination
    # :source is hops seen sent from the source
    # and :destination is hops seen sent towards the destination
    #
    # pre: self.Host2Site is initialized
    def self.historical_pl_pl_hops
        direction2host2hops = YAML.load_file(HistoricalPLPLHopsPath)
        direction2site2hops = Hash.new { |h,k| h[k] = Hash.new { |h1,k1| h1[k1] = [] } }
        direction2host2hops.each do |direction, host2hops|
            host2hops.each do |host, hops|
                direction2site2hops[direction][self.Host2Site[host]] |= hops 
            end
        end
        direction2site2hops
    end

    SiteMapper = "/homes/network/ethan/scripts/list_sites_for_pl_hosts_in_fileX.pl"
       
    def self.Host2Site()
        return @Host2Site unless @Host2Site.nil?
        @Host2Site = Hash.new { |h,k| k }
        @Host2Site.merge!(`#{SiteMapper} #{$DATADIR}/pl_hostnames_w_ips.txt | cut -d ' ' -f1,3`\
                                          .split("\n").map { |line| line.split }.to_hash)
    end

    def self.Site2Hosts()
        return @Site2Hosts unless @Site2Hosts.nil?
        @Site2Hosts = Hash.new { |h,k| [] }
        @Site2Hosts.merge!(self.Host2Site.value2keys)
    end

    # ====================================
    #         Data Directories           #
    # ====================================
    IsolationResults = "#{$DATADIR}/isolation_results_final"
    MergedIsolationResults = "#{$DATADIR}/merged_isolation_results"
    Snapshot = "#{$DATADIR}/isolation_results_snapshot"

    OutageCorrelation = "#{$DATADIR}/outage_correlation" 

    DotFiles = "#{$DATADIR}/dots"

    WebDirectory = "/homes/network/revtr/www/isolation_graphs"

    PingMonitorState = "~/colin/target_state.yml"
    PingMonitorRepo = "#{$DATADIR}/ping_monitoring_state/"

    HistoricalTraces = "#{$DATADIR}/most_recent_historical_traces.txt"

    DataSetDir = "/homes/network/revtr/spoofed_traceroute/datasets"

    PingStatePath = "/homes/network/revtr/spoofed_traceroute/data/ping_monitoring_state"
    
    # ====================================
    #         Target Sets                #
    # ====================================
    TargetSetPath = "/homes/network/revtr/spoofed_traceroute/current_target_set.txt"
    def self.TargetSet
        if @TargetSet.nil?
            self.ReadInDataSets()
        end

        @TargetSet
    end

    TargetBlacklistPath = "/homes/network/revtr/spoofed_traceroute/target_blacklist.txt"
    def self.TargetBlacklist()
        @TargetBlacklist ||= Set.new(IO.read(TargetBlacklistPath).split("\n"))
    end

    # targets taken from Harsha's most well connected PoPs
    HarshaPoPsPath = "#{DataSetDir}/responsive_corerouters.txt"
    def self.HarshaPoPs()
        @HarshaPoPs ||= Set.new(IO.read(HarshaPoPsPath).split("\n"))
    end

    # targets taken from routers on paths beyond Harsha's most well connected PoPs
    BeyondHarshaPoPsPath = "#{DataSetDir}/responsive_edgerouters.txt"
    def self.BeyondHarshaPoPs()
        @BeyondHarshaPoPs ||= Set.new(IO.read(BeyondHarshaPoPsPath).split("\n"))
    end

    # For Ethan's PL-PL traceroutes -- <hostname> <ip> <site>
    SpooferTargetsMetaDataPath = "#{DataSetDir}/up_spoofers_w_sites.txt"
    #  XXX Take in from isolation_vantage_points table instaed of this static list.
    SpooferTargetsPath = "#{DataSetDir}/up_spoofers.ips"
    def self.SpooferTargets()
        @SpooferTargets ||= Set.new(IO.read(SpooferTargetsPath).split("\n"))
    end

    # targets taken from cloudfront ips
    CloudfrontTargetsPath = "#{DataSetDir}/cloudfront_ips.txt"
    def self.CloudfrontTargets()
        @CloudfrontTargets ||= Set.new(IO.read(CloudfrontTargetsPath).split("\n"))
    end

    # targets taken from AT&T ips, for potential ground truth
    ATTTargetsPath = "/homes/network/revtr/dave/revtr-test/reverse_traceroute/data/att_responsive_just_ips.txt"
    def self.ATTTargets()
        @ATTTargets ||= Set.new(IO.read(ATTTargetsPath).split("\n"))
    end

    # !!!!!!!!!!!!!!!!!!!
    #   to add a dataset, mimick the above lines
    def self.get_dataset(dst)
        if HarshaPoPs.include? dst
            return DataSets::HarshaPoPs
        elsif BeyondHarshaPoPs.include? dst
            return DataSets::BeyondHarshaPoPs 
        elsif CloudfrontTargets.include? dst
            return DataSets::CloudfrontTargets
        elsif SpooferTargets.include? dst
            return DataSets::SpooferTargets
        elsif ATTTargets.include? dst
            return DataSets::ATTTargets
        else
            return DataSets::Unknown 
        end
    end

    def self.ReadInDataSets()
        @Host2Site = nil
        self.Host2Site
        @Site2Hosts = nil
        self.Site2Hosts
        @HarshaPoPs = nil
        self.HarshaPoPs
        @BeyondHarshaPoPs = nil
        self.BeyondHarshaPoPs
        @SpooferTargets = nil
        self.SpooferTargets
        @CloudfrontTargets = nil
        self.CloudfrontTargets
        # pops are symbols!
        @IPToPoPMapping = nil
        self.IPToPoPMapping
        @TargetBlacklist = nil
        self.TargetBlacklist
        @ATTTargets = nil
        self.ATTTargets
        self.UpdateTargetSet()
    end

    def self.UpdateTargetSet()
        @TargetSet = Set.new
        union = DataSets::AllDataSets.reduce(Set.new) { |sum,arr| sum | arr }
        @TargetSet.merge(union)
        File.open(TargetSetPath, "w") { |f| f.puts @TargetSet.to_a.join "\n" }
    end

    # ====================================
    #         Vantage Points             #
    # ====================================

    NumActiveNodes = 13

    AllNodesPath = "/homes/network/revtr/spoofed_traceroute/all_isolation_nodes.txt"
    def self.AllNodes()
        @AllNodes ||= Set.new(IO.read(AllNodesPath).split("\n"))
    end

    NodeBlacklistPath = "/homes/network/revtr/spoofed_traceroute/blacklisted_isolation_nodes.txt"
    def self.NodeBlacklist()
        @NodeBlacklist ||= Set.new(IO.read(NodeBlacklistPath).split("\n"))
    end

    CurrentNodesPath = "/homes/network/revtr/spoofed_traceroute/cloudfront_spoofing_monitoring_nodes.txt"
    def self.CurrentNodes()
        @CurrentNodes ||= Set.new(IO.read(CurrentNodesPath).split("\n"))
    end

    ToilNodesPath = "/home/cs/colin/ping_monitoring/cloudfront_monitoring/cloudfront_spoofing_monitoring_nodes.txt"

    NodeToRemovePath = "/homes/network/revtr/spoofed_traceroute/data/sig_usr2_node_to_remove.txt"

    def self.ReadInNodeSets()
        @AllNodes = nil
        self.AllNodes

        @NodeBlacklist = nil
        self.NodeBlacklist

        @CurrentNodes = nil
        self.CurrentNodes
    end

    # =========================
    #   Top Pops Regeneration #
    # =========================
    
    # More than actually needed
    NumTopPoPs = 200

    CoreRtrsPerPoP = 1
    EdgeRtrsPerPoP = 2

    IPToPoPMappingPath = "/homes/network/harsha/logs_dir/curr_clustering/curr_ip_to_pop_mapping.txt"

    # PoPs are symbols!
    def self.IPToPoPMapping()
        return  @IPToPoPMapping unless @IPToPoPMapping.nil?
        @IPToPoPMapping = Hash.new { |h,k| PoP::Unknown }
        @IPToPoPMapping.merge!(IO.read(IPToPoPMappingPath)\
                              .split("\n").map { |line| line.split }.map { |ippop| [ippop[0], ippop[1].to_sym] }.to_hash)
    end

    TopPoPsScripts = "/homes/network/revtr/spoofed_traceroute/harshas_new_targets/generate_N_top_pops.sh"

    # Connectivity ranking for top N PoPs.       Format: <pop #> <number of traversing paths> <max paths from any one VP?> <total VPs>
    TopN = "/homes/network/revtr/spoofed_traceroute/harshas_new_targets/top_500.txt"
    # trace.out files for the VPs passing through the top 500 pops. Format: <trace.out> <total # paths> <# paths passing through top 100 pops>. Last line is total overall.
    SelectedPaths = "/homes/network/revtr/spoofed_traceroute/harshas_new_targets/selected_paths.txt"
    # PL sources and targets for top 500 PoPs. Format: <pop #> <PL node> <target>
    SourceDests = "/homes/network/revtr/spoofed_traceroute/harshas_new_targets/srcdsts.txt"

    # =========================
    #   aliases               #
    # =========================
    class << self 
        alias :Node2Site :Host2Site
        alias :Site2Nodes :Site2Hosts
    end
end

# constants for names of datasets (not targets themselves)
module DataSets
    HarshaPoPs = :"Harsha's most well-connected PoPs"
    BeyondHarshaPoPs = :"Routers on paths beyond Harsha's PoPs"
    CloudfrontTargets = :"CloudFront"
    SpooferTargets = :"PL/mlab nodes"
    Unknown = :"Unknown"
    ATTTargets = :"ATT"

    # !!!!!!!!!!!!!!!
    #  to add a dataset, add an element to this array, and edit
    #  the path in FailureIsolation. Note that these are the Sets! not the
    #  symbols
    AllDataSets = [FailureIsolation.HarshaPoPs, FailureIsolation.BeyondHarshaPoPs,
        FailureIsolation.CloudfrontTargets, FailureIsolation.SpooferTargets,FailureIsolation.ATTTargets]

    def self.ToPath(dataset)
        case dataset
        when HarshaPoPs
            return FailureIsolation.HarshaPoPsPath
        when BeyondHarshaPoPs
            return FailureIsolation.BeyondHarshaPoPsPath
        when CloudfrontTargets
            return FailureIsolation.CloudfrontTargetsPath
        when SpooferTargets
            return FailureIsolation.SpooferTargetsPath
        when ATTTargets
            return FailureIsolation.ATTTargetsPath
        when Unknown
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

if $0 == __FILE__
    FailureIsolation.ReadInDataSets
    FailureIsolation.ReadInNodeSets
    #puts FailureIsolation.Site2Hosts.inspect
    #puts FailureIsolation.Host2Site.inspect
    #puts FailureIsolation.current_hops_on_pl_pl_traces_to_site("arizona-gigapop.net").to_a.inspect
end