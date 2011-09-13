require 'yaml'
require 'time'
require 'utilities'

class Update
    attr_accessor :feed_box, :time, :announce, :withdrawl, :prefix, :as_path

    def initialize(feed_box, split)
        # BGP4MP|1301923627|A|192.203.154.1|9560|130.195.0.0/18|9560 23655 23905 23905 23905 23905|INCOMPLETE|192.203.154.120|0|0|23655:101 23655:204|NAG||
        # BGP4MP|1301923620|W|192.203.154.2|9560|130.195.0.0/18
        # Type | Unix time | Announce / Withdrawl | Peer IP | Peer ASN | Announced Prefix | AS_PATH | Origin | Peer IP | ? | ? | Special info |
        @feed_box = feed_box
        @time = Time.at(split[1].to_i)
        @announce = split[2] == "A"
        @withdrawl = !@announce
        @prefix = split[5]
        @as_path = split[6].split(' ') if @announce
    end
end

module Util
    PCH_PATH = "/homes/network/revtr/failure_isolation/outage_duration_prediction/pch"
    ALL_PCH_FILES = Dir.glob(PCH_PATH+"/*filter")
    FORWARD_OUTAGE_DURATION_PATH = "/homes/network/revtr/failure_isolation/outage_duration_prediction/outage_tuples/forward_path_only_outage_durations.yml"
    DST_2_PREFIX_PATH = "/homes/network/revtr/failure_isolation/outage_duration_prediction/outage_tuples/dests_w_prefixes.txt"
    ALL_OUTAGE_DURATION_PATH = ""

    def self.load_prefix2sorted_updates
        prefix2sorted_updates = Hash.new { |h,k| h[k] = [] }

        ALL_PCH_FILES.each do |file|
            # BGP4MP|1301923627|A|192.203.154.1|9560|130.195.0.0/18|9560 23655 23905 23905 23905 23905|INCOMPLETE|192.203.154.120|0|0|23655:101 23655:204|NAG||
            # BGP4MP|1301923620|W|192.203.154.2|9560|130.195.0.0/18
            # Type | Unix time | Announce / Withdrawl | From | From ASN | Announced Prefix | AS_PATH | Origin | Peer IP | | ? | Special info |

            File.foreach(file) do |line|
                split = ""
                begin
                    split = line.chomp.split('|')
                rescue => e
                    $stderr.puts e
                    $stderr.puts split
                    next
                end
                update = Update.new(file, split)
                prefix2sorted_updates[update.prefix] << update
            end
        end

        prefix2sorted_updates.map_values { |updates| updates.sort_by { |u| u.time } }
    end

    # src_dst2start_ends
    def self.load_forward_outages()
        YAML.load_file(FORWARD_OUTAGE_DURATION_PATH)
    end

    def self.load_dst2prefix
        dst2prefix = {}
        File.foreach(DST_2_PREFIX_PATH) do |line|
            dst, prefix = line.chomp.split
            dst2prefix[dst] = prefix
        end
    end
end

