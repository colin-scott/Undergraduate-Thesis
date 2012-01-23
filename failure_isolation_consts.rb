#!/homes/network/revtr/ruby-upgrade/bin/ruby

$: << "./"

# Constants (and assorted convenience methods) for the isolation system.
#
# Lazily evaluates all large datasets

require 'set'
require 'isolation_utilities.rb'
require 'yaml'

# Define these in case spooftr_config.rb was not loaded
$REV_TR_TOOL_DIR ||= "/homes/network/revtr/spoofed_traceroute/reverse_traceroute"
$DATADIR ||= "/homes/network/revtr/spoofed_traceroute/data"

# Constants for the entire isolation system
module FailureIsolation
    # ====================================
    #         miscellaneous              #
    # ====================================
    # Running on riot.cs.washington.edu
    PoisonerNames = Set.new(["UWAS.BGPMUX", "PRIN.BGPMUX", "WISC.BGPMUX", "CLEM.BGPMUX", "GATE.BGPMUX",
                             "uwas.bgpmux", "prin.bgpmux", "wisc.bgpmux", "clem.bgpmux", "gate.bgpmux",
                             "UWAS.SENTINEL", "PRIN.SENTINEL", "WISC.SENTINEL", "CLEM.SENTINEL", "GATE.SENTINEL",
                             "uwas.sentinel", "prin.sentinel", "wisc.sentinel", "clem.sentinel", "gate.sentinel"])
    
    # Length of each isolation round
    DefaultPeriodSeconds = 360

    # Number of rounds a VP is allowed to be unregsitered before it is swapped out
    UnregisteredRoundsThreshold = 5
    # Maximum number of VPs to swap out at any time. Greater than this
    # indicates that something is very wrong...
    SwapOutThreshold = 3

    PPTASKS = "~ethan/scripts/pptasks"

    TestPing = "128.208.4.49" # crash.cs.washington.edu
    TestSpoofPing = "169.229.49.105" # c5.millennium.berkeley.edu
    TestSpoofReceiver = "crash.cs.washington.edu"

    MonitorSlice = "uw_revtr2"
    IsolationSlice = "uw_revtr" # TODOC: why do we separate the slices?

    RevtrRequests = "/homes/network/revtr/failure_isolation/revtr_requests/current_requests.txt"

    ControllerUri = ($TEST) ? IO.read("#{$DATADIR}/uris/test_controller.txt").chomp : IO.read("#{$DATADIR}/uris/controller.txt").chomp
    RegistrarUri = ($TEST) ? IO.read("#{$DATADIR}/uris/test_registrar.txt").chomp : IO.read("#{$DATADIR}/uris/registrar.txt").chomp

    ReadTraces = "~revtr/colin/Scripts/readouttraces"
    HopsTowardsSrc = "/homes/network/revtr/colin/Scripts/gather_hops_on_traces_towards_ipsX_input_filesY\*"

    HistoricalPLPLHopsPath = "/homes/network/revtr/spoofed_traceroute/data/historical_pl_pl_hops.yml"

    CurrentPLPLTracesPath = "/homes/network/ethan/failures/pl_pl_traceroutes/logs/currentlogdir/probes"

    EmptyPingsLogDir = "/homes/network/revtr/revtr_logs/isolation_logs/empty_pings_logs"

    # Return all hops observed on most recent traceroutes from all PL nodes to
    # the given site
    #
    # TODO: move me to a more "dynamic" module, e.g. failure_analyzer.rb
    def self.current_hops_on_pl_pl_traces_to_site(db, site)
        self.hops_on_pl_pl_traces_to_site(db, site, CurrentPLPLTracesPath)
    end

    # Return the path to the directory containing Ethan's PL-PL paths for the
    # given time object (time rounded to nearsest 5 minutes)
    #
    # TODO: move me to a more "dynamic" module, e.g. failure_analyzer.rb
    def self.pl_pl_path_for_date(time)
        root = "/homes/network/ethan/failures/pl_pl_traceroutes/logs/"
        base = time.strftime("%Y/%m/%d/")
        up_to_day = root+base

        hour_minute = time.strftime("%H%M")

        hour_minutes = []
        Dir.chdir(up_to_day) do
            hour_minutes = Dir.glob("*").sort
        end
        idx = hour_minutes.binary_search(hour_minute)
        idx = (idx < 0) ? -idx-1 : idx
              
        hour_minute = hour_minutes[idx]
        hour_minute = hour_minutes[-1] if hour_minute.nil?

        up_to_day+"/"+hour_minute+"/probes"
    end

    # Return all hops ever observed on historical PL-PL traces to the given
    # site.
    #
    # TODO: move me to a more "dynamic" module, e.g. failure_analyzer.rb
    # current pl pl traces, for pruning
    def self.hops_on_pl_pl_traces_to_site(db, site, path)
        return nil unless self.Site2Hosts.include? site
        all_src_ips = self.Site2Hosts[site].map { |host| db.hostname2ip[host] }
        File.open("/tmp/site_hosts.txt", "w") { |f| f.puts all_src_ips.join "\n" }
        Set.new(`#{HopsTowardsSrc} /tmp/site_hosts.txt #{path}/*`.split("\n"))
    end

    # returns direction2site2hops,
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
       
    # Lazily evaluate hostname -> site mapping
    def self.Host2Site()
        return @Host2Site unless @Host2Site.nil?
        @Host2Site = Hash.new { |h,k| k }
        system "cut -d ' ' -f1 #{$DATADIR}/pl_hostnames_w_ips.txt > #{$DATADIR}/pl_hosts.txt", :err => "#{$REV_TR_TOOL_DIR}/failure_isolation_consts.err"
        @Host2Site.merge!(`#{SiteMapper} #{$DATADIR}/pl_hosts.txt`\
                                          .split("\n").map { |line| line.split }.custom_to_hash)
    end

    # Lazily evaluate site -> hostname mapping
    def self.Site2Hosts()
        return @Site2Hosts unless @Site2Hosts.nil?
        @Site2Hosts = Hash.new { |h,k| [] }
        @Site2Hosts.merge!(self.Host2Site.value2keys)
    end

    # ====================================================== 
    # Historical traceroutes from isolation VPs -> targets #
    # ====================================================== 
    def self.HistoricalTraceTimestamp
        self.grab_historical_traces unless @HistoricalTraceTimestamp
        @HistoricalTraceTimestamp
    end

    def self.Node2Target2Trace
        self.grab_historical_traces unless @Node2Target2Trace
        @Node2Target2Trace
    end

    # Grab historical traceroutes (also called on demand when the SIGWINCH
    # signal is sent
    def self.grab_historical_traces
        # TODO: put traces in the DB
        @HistoricalTraceTimestamp, node2target2trace = YAML.load_file FailureIsolation::HistoricalTraces
        @Node2Target2Trace = {}
        node2target2trace.each do |node, target2trace|
            @Node2Target2Trace[node.downcase] = target2trace 
        end
    end
    
    # ====================================
    #         Poisoning scripts          #
    # ====================================
    PoisoningDashboardPath = "/homes/network/revtr/poisoning_dashboard"
    # Script to execute a poison
    ExecutePoisonPath = "#{PoisoningDashboardPath}/execute_poison.rb"
    # Script to execute a poison
    UnpoisonPath = "#{PoisoningDashboardPath}/unpoison.rb"
    # Log of poisonings
    PoisonLogPath = "#{PoisoningDashboardPath}/poison_log.yml"
    # Human-readable display of current poisonings
    CurrentPoisoningsPath = "#{PoisoningDashboardPath}/who_is_currently_poisoned?.rb"

    # ====================================
    #         Data Directories           #
    # ====================================
    # Metadata for the FailureMonitor
    NonReachableTargetPath = "#{$DATADIR}/targets_never_seen.yml"
    LastObservedOutagePath = "#{$DATADIR}/last_outages.yml"

    # Outage logs
    IsolationResults = "#{$DATADIR}/isolation_results_final"
    MergedIsolationResults = "#{$DATADIR}/merged_isolation_results"
    Snapshot = "#{$DATADIR}/isolation_results_snapshot"

    # Logs of filter (first level, registration, and second level) statistics
    FilterStatsPath = "#{$DATADIR}/filter_stats"

    # Web links
    WebDirectory = "/homes/network/revtr/www/isolation_graphs"
    DotFiles = "#{$DATADIR}/dots"

    # Ping results from VPs for most recent round
    PingMonitorStatePath = "/home/uw_revtr2/colin/"
    PingStatePath = "#{$DATADIR}/ping_monitoring_state/"

    # Historical forward traceroutes gathered from VPS. TODO: move these to
    # the bouncer DB
    HistoricalTraces = "#{$DATADIR}/most_recent_historical_traces.txt"

    # Target lists
    DataSetDir = "/homes/network/revtr/spoofed_traceroute/datasets"
    
    # ====================================
    #         Target Sets                #
    # ====================================
    ToilTargetSetPath = "/home/cs/colin/ping_monitoring/cloudfront_targets/current_target_set.txt"
    MonitorTargetSetPath = "/home/uw_revtr2/colin/current_target_set.txt"

    TargetSetPath = "/homes/network/revtr/spoofed_traceroute/current_target_set.txt"
    def self.TargetSet
        if @TargetSet.nil?
            self.ReadInDataSets()
        end

        @TargetSet
    end

    TargetBlacklistPath = "/homes/network/revtr/spoofed_traceroute/target_blacklist.txt"
    def self.TargetBlacklist()
        @TargetBlacklist ||= Set.new(IO.read(TargetBlacklistPath).split("\n").map { |s| s.strip })
    end

    # targets taken from Harsha's most well connected PoPs
    HarshaPoPsPath = "#{DataSetDir}/responsive_corerouters.txt"
    def self.HarshaPoPs()
        @HarshaPoPs ||= Set.new(IO.read(HarshaPoPsPath).split("\n").map { |s| s.strip })
    end

    # targets taken from routers on paths beyond Harsha's most well connected PoPs
    BeyondHarshaPoPsPath = "#{DataSetDir}/responsive_edgerouters.txt"
    def self.BeyondHarshaPoPs()
        @BeyondHarshaPoPs ||= Set.new(IO.read(BeyondHarshaPoPsPath).split("\n").map { |s| s.strip })
    end

    # For Ethan's PL-PL traceroutes -- <hostname> <ip> <site>
    SpooferTargetsMetaDataPath = "#{DataSetDir}/up_spoofers_w_sites.txt"
    # TODO: Take in from isolation_vantage_points table instaed of this static list.
    SpooferTargetsPath = "#{DataSetDir}/up_spoofers.ips"
    def self.SpooferTargets()
        @SpooferTargets ||= Set.new(IO.read(SpooferTargetsPath).split("\n").map { |s| s.strip })
    end

    # targets taken from cloudfront ips
    CloudfrontTargetsPath = "#{DataSetDir}/cloudfront_ips.txt"
    def self.CloudfrontTargets()
        @CloudfrontTargets ||= Set.new(IO.read(CloudfrontTargetsPath).split("\n").map { |s| s.strip })
    end

    # targets taken from AT&T ips, for potential ground truth
    ATTTargetsPath = "/homes/network/revtr/dave/revtr-test/reverse_traceroute/data/att_responsive_just_ips.txt"
    def self.ATTTargets()
        @ATTTargets ||= Set.new(IO.read(ATTTargetsPath).split("\n").map { |s| s.strip })
    end

    # targets taken from cloudfront ips
    HubbleTargetsPath = "#{DataSetDir}/hubble_targets.txt"
    def self.HubbleTargets
        @HubbleTargets ||= Set.new(IO.read(HubbleTargetsPath).split("\n").map { |s| s.strip })
    end

    # Helper method:
    def self.read_in_riot_ips(remote_path)
        tmp_path = "/tmp/riot_nodes.txt"
        system "scp #{remote_path} #{tmp_path}", :err => "#{$REV_TR_TOOL_DIR}/failure_isolation_consts.err"
        ips = Set.new

        File.foreach(tmp_path) do |line|
           node, ip, device = line.chomp.split 
           ips.add ip
        end

        ips
    end

    MuxNodesPath = "cs@riot.cs.washington.edu:~/nodename_ip_device.txt"
    def self.MuxNodes
        @MuxNodes ||= self.read_in_riot_ips(MuxNodesPath)
    end

    SentinelNodesPath = "cs@riot.cs.washington.edu:~/sentinelname_ip_device.txt"
    def self.SentinelNodes
        @SentinelNodes ||= self.read_in_riot_ips(SentinelNodesPath)
    end

    # NOTE: to add a dataset, mimick the above lines
    def self.get_dataset(dst)
        if self.HarshaPoPs.include? dst
            return DataSets::HarshaPoPs
        elsif self.BeyondHarshaPoPs.include? dst
            return DataSets::BeyondHarshaPoPs 
        elsif self.CloudfrontTargets.include? dst
            return DataSets::CloudfrontTargets
        elsif self.SpooferTargets.include? dst
            return DataSets::SpooferTargets
        elsif self.ATTTargets.include? dst
            return DataSets::ATTTargets
        elsif self.HubbleTargets.include? dst
            return DataSets::HubbleTargets
        elsif self.MuxNodes.include? dst
            return DataSets::MuxNodes
        elsif self.SentinelNodes.include? dst
            return DataSets::SentinelNodes
        else
            return DataSets::Unknown 
        end
    end

    # Evaluate all of the lazily-evaluated datasets
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
        @HubbleTargets = nil
        self.HubbleTargets
        @MuxNodes = nil
        self.MuxNodes
        @SentinelNodes = nil
        self.SentinelNodes
        self.UpdateTargetSet()
    end

    # Compute the set of unique targets
    def self.UpdateTargetSet()
        @TargetSet = Set.new
        union = DataSets::AllDataSets.reduce(Set.new) { |sum,arr| sum | arr }
        @TargetSet.merge(union)

        not_valid_ip = @TargetSet.find { |ip| !ip.matches_ip? }
        raise "Invalid IP address in targets! #{not_valid_ip}" if not_valid_ip

        File.open(TargetSetPath, "w") { |f| f.puts @TargetSet.to_a.join "\n" }
        # push out targets to monitoring nodes! 
        system "#{FailureIsolation::PPTASKS} scp #{FailureIsolation::MonitorSlice} #{FailureIsolation::CurrentNodesPath} 100 100 \
                    #{TargetSetPath} @:#{MonitorTargetSetPath}", :err => "#{$REV_TR_TOOL_DIR}/failure_isolation_consts.err"
        # also push out target set to toil in case it restarts nodes
        system "scp #{TargetSetPath} cs@toil.cs.washington.edu:#{ToilTargetSetPath}", :err => "#{$REV_TR_TOOL_DIR}/failure_isolation_consts.err"
        # ============================== #
        #      riot specific!            #
        # ============================== #
        system "scp #{TargetSetPath} cs@riot.cs.washington.edu:~/ping_monitors/", :err => "#{$REV_TR_TOOL_DIR}/failure_isolation_consts.err"
    end

    # ====================================
    #         Vantage Points             #
    # ====================================

    # Number of unique VPs issuing pings 
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

    # Signal to failure_monitor to update it's metadata for a removed VP
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
    NumTopPoPs = 400

    CoreRtrsPerPoP = 1
    EdgeRtrsPerPoP = 2

    IPToPoPMappingPath = "/homes/network/harsha/logs_dir/curr_clustering/curr_ip_to_pop_mapping.txt"

    # Lazily evaluate IP -> Harsha's POP ID mapping
    # PoPs are symbols!
    def self.IPToPoPMapping()
        return  @IPToPoPMapping unless @IPToPoPMapping.nil?
        @IPToPoPMapping = Hash.new { |h,k| PoP::Unknown }
        @IPToPoPMapping.merge!(IO.read(IPToPoPMappingPath)\
                              .split("\n").map { |line| line.split }.map { |ippop| [ippop[0], ippop[1].to_sym] }.custom_to_hash)
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
    HubbleTargets = :"Hubble Targets"
    MuxNodes = :"Mux Nodes"
    SentinelNodes = :"Sentinel Nodes"

    # NOTE: 
    #  to add a dataset, add an element to this array, and edit
    #  the path in FailureIsolation. Note that these are the Sets! not the
    #  symbols
    AllDataSets = [FailureIsolation.HarshaPoPs, FailureIsolation.BeyondHarshaPoPs,
        FailureIsolation.CloudfrontTargets, FailureIsolation.SpooferTargets,FailureIsolation.ATTTargets,
        FailureIsolation.MuxNodes, FailureIsolation.SentinelNodes]
    #   ,FailureIsolation.HubbleTargets]

    def self.ToPath(dataset)
        case dataset
        when HarshaPoPs
            return FailureIsolation::HarshaPoPsPath
        when BeyondHarshaPoPs
            return FailureIsolation::BeyondHarshaPoPsPath
        when CloudfrontTargets
            return FailureIsolation::CloudfrontTargetsPath
        when SpooferTargets
            return FailureIsolation::SpooferTargetsPath
        when ATTTargets
            return FailureIsolation::ATTTargetsPath
        when HubbleTargets
            return FailureIsolation::HubbleTargetsPath
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
    puts `#{FailureIsolation::CurrentPoisoningsPath}`
    puts FailureIsolation.SpooferTargets.to_a.inspect
    #puts FailureIsolation.MuxNodes.inspect
    #puts FailureIsolation.SentinelNodes.inspect
    #puts FailureIsolation.TargetSet.inspect

    #puts Dir.glob("#{FailureIsolation::PingStatePath}*yml").inspect
    #require 'thread'
    #Thread.abort_on_exception = true

    #Thread.new { sleep }

    #require 'time'
    #t = Time.parse("2011-09-19 11:40:43 -0700")
    #
    #puts FailureIsolation.pl_pl_path_for_date(t)

    #puts FailureIsolation.TargetSet.size


    require 'yaml'
    #puts previous_outages.inspect

    #a = FailureIsolation.ATTTargets
    #t = FailureIsolation.TargetSet
    #$stderr.puts (a - t).to_a.inspect
    ##FailureIsolation.ReadInDataSets
    #FailureIsolation.ReadInNodeSets
    #puts FailureIsolation.Site2Hosts.inspect
    #puts FailureIsolation.Host2Site.inspect
    #puts FailureIsolation.current_hops_on_pl_pl_traces_to_site("arizona-gigapop.net").to_a.inspect
end
