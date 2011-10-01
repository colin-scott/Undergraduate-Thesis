
$: << File.expand_path("../")

require 'outage'
require 'set'
require 'hops'
require 'yaml'

module Fixture
    def self.merged_outage
        o = YAML.load_file("./outage.yml")

        m = MergedOutage.new([o])
    end

    def self.historical_revtr
       #HistoricalReversePath.new(["96.7.8.189", "189.68.86.52", "220.134.106.254", "118.208.115.118", "62.152.227.42", "79.87.232.160", "98.11.85.75", "77.88.24.95"].map { |i| Hop.new(i) } )
       YAML.load_file("./outage.yml").historical_revtr
    end

    def self.responsive_targets
        ["189.46.2.122", "201.170.174.173", "201.114.46.168"]
    end

    def self.suspect_set
        Set.new(["189.46.2.122", "201.170.174.173", "201.114.46.168", "189.237.2.45", "79.93.4.171", "79.145.243.70", "70.18.128.42", "71.217.7.3", "124.142.15.160", "76.81.175.78", "99.195.90.236", "75.171.129.144", "91.194.241.18", "189.73.88.56", "76.11.225.27", "211.47.220.84", "207.112.108.1", "201.152.196.200", "189.15.116.85", "118.10.238.100", "71.255.28.28", "67.107.184.98", "92.31.255.39", "71.255.28.29", "124.142.15.164", "74.4.35.68", "189.27.207.86", "128.239.152.137", "200.169.95.158", "201.124.61.31", "203.193.200.2", "210.11.127.1", "98.10.103.34", "97.70.70.221", "72.233.89.47", "71.168.39.3", "118.10.238.104", "98.0.230.213", "67.150.170.209", "71.168.56.177", "89.231.207.154", "74.54.105.251", "193.49.72.1", "208.76.184.74", "71.168.39.5", "98.10.103.37", "117.58.231.71", "83.212.240.130", "79.170.40.130", "118.10.55.185"])
    end
end
