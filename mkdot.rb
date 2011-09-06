#!/homes/network/revtr/ruby/bin/ruby

# TODO:
#    * This code is shite. Refactor just about everything. esp. add_path()
#    * handle 0.0.0.0's more elegantly. To collapse too many 0.0.0.0's, what if we name the 0.0.0.0
#       nodes as the hop before them and the hop after them, and say the number of *s in a row? this
#       would collapse these cases while keeping distinct ones that should be distinct
#    * For paths that don't reach, should we connect them to the dst / src, with a special edge indicating 
#        that it didn't work? This will tie the images together.
#    * use a different alias dataset
#    * label the reverse links were symmetry was assumed
#    * graphs really need a legend -> include a link in the emails 
#    * fix the bug where there are gaps in the spoofed traceroute ttls ->
#         false edges

require 'hops'
require 'set'
require 'ip_info'
require 'resolv'
require 'utilities'

$ip2cluster ||= Hash.new { |h,k| k } # loaded by isolation_module.rb

class DotGenerator
    def initialize(logger = LoggerLog.new($stderr))
        @logger = logger
    end

    DotGenerator::Colors = ["aquamarine",  "blue", "blueviolet", "brown", "cadetblue", "chartreuse", "chocolate", "coral", "cornflowerblue", "crimson", "cyan", "darkgoldenrod1", "darkgreen", 
                     "darkolivegreen", "darkorange", "darkorchid", "darkslateblue", "forestgreen", "deeppink1", "firebrick1", "gold", "green", "indigo", "midnightblue", "red", 
                     "saddlebrown", "violetred1", "springgreen", "bisque"]

    def generate_jpg(src, dst, direction, dataset, tr, spoofed_tr, historic_tr, revtr, historic_revtr, additional_traces,
                         upstream_reverse_paths, output)
        raise "Output file must be a .jpg!" unless output =~ /\.jpg$/
        dot_output = output.gsub(/\.jpg$/, ".dot")
        create_dot_file(src, dst, direction, dataset, tr, spoofed_tr, historic_tr, revtr, historic_revtr, additional_traces, upstream_reverse_paths, dot_output)
        # TODO: once support installs graphviz on slider, I should run dot
        # locally rather than pushing the bits across the wire
        File.open(output, "w") { |f| f.puts `cat #{dot_output} | ssh cs@toil "dot -Tjpg" ` } 
    end

    def create_dot_file(src, dst, direction, dataset, tr, spoofed_tr, historic_tr, revtr, historic_revtr, additional_traces, upstream_reverse_paths, output)
        # we want to keep all 0.0.0.0's distinct in the final graph, so
        # we append this marker to each 0.0.0.0 node to keep them distinct
        oooo_marker = "a" # FUUCKKK. this is ugly 

        # the source is not included in the forward traceroutes, so we insert
        # a mock hop object into the beginning of the paths
        src_hop = MockHop.new((Resolv.getaddress(src) rescue src), src, 0, nil, true, true, [], true)
        tr = ForwardPath.new([src_hop] + tr)
        spoofed_tr = ForwardPath.new([src_hop] + spoofed_tr)
        historic_tr = ForwardPath.new([src_hop] + historic_tr)

        # Cluster -> dns names we have seen for the cluster
        node2names = Hash.new{|h,k| h[k] = []}
        
        # cluster -> ( attribute -> value )
        node_attributes=Hash.new{|hash,key| hash[key]= Hash.new}

        # [cluster,cluster] -> (attribute -> value)
        edge_attributes=Hash.new{|hash,key| hash[key]= Hash.new(0)}

        # [cluster,cluster]
        symmetric_revtr_links = Set.new

        # non-symmetric revtr links... sometimes the same link is seen
        # symmetric once but measured on some other path...
        # in that case, we really want to say that the link did not assume
        # symmetry
        non_symmetric_revtr_links = Set.new
        
        # cluster -> (cluster -> bool)
        node2neighbors=Hash.new{|hash,key| hash[key]=Hash.new(false)}
        
        # [cluster,cluster,measurement_type]->bool
        # whether it was seen in, say, traceroutes
        edge_seen_in_measurements=Hash.new(false)

        # cluster -> pingable?
        node2pingable = {}

        # cluster -> historically pingable?
        node2historicallypingable = Hash.new(false)

        # set of all ASes
        node2asn = {}

        # is a node not pingable from S, but pingable from other VPs?
        node2othervpscanreach = {}

        # XXX hmmmm, so many parameters...  TODO: encapsulate all of this into a
        # one-time-use object? Orrrrrrr... fill in all of the node attributes
        # separately from add_path(). Satan
        add_path(tr, :tr, node2names, node2pingable, node2historicallypingable, node2othervpscanreach, symmetric_revtr_links, non_symmetric_revtr_links, node2neighbors, edge_seen_in_measurements, node2asn, oooo_marker)
        additional_traces.each do |target, trace|
            add_path(trace, :aux_tr, node2names, node2pingable, node2historicallypingable, node2othervpscanreach, symmetric_revtr_links, non_symmetric_revtr_links, node2neighbors, edge_seen_in_measurements, node2asn, oooo_marker)
        end

        
        add_path(spoofed_tr, :spoofed_tr, node2names, node2pingable, node2historicallypingable, node2othervpscanreach,symmetric_revtr_links, non_symmetric_revtr_links, node2neighbors, edge_seen_in_measurements, node2asn, oooo_marker)
        add_path(historic_tr, :historic_tr, node2names, node2pingable, node2historicallypingable,node2othervpscanreach, symmetric_revtr_links, non_symmetric_revtr_links, node2neighbors, edge_seen_in_measurements, node2asn, oooo_marker)

        #XXX
        #hop = historic_tr[-4]
        #puts hop.dns
        #puts hop.reverse_path
        #add_path(hop.reverse_path, :historic_revtr, node2names, node2pingable, node2historicallypingable, node2othervpscanreach,symmetric_revtr_links, non_symmetric_revtr_links, node2neighbors, edge_seen_in_measurements, node2asn, oooo_marker) unless hop.is_a?(MockHop)

        historic_tr.each do |hop|
            add_path(hop.reverse_path, :historic_revtr, node2names, node2pingable, node2historicallypingable, node2othervpscanreach,symmetric_revtr_links, non_symmetric_revtr_links, node2neighbors, edge_seen_in_measurements, node2asn, oooo_marker) unless hop.is_a?(MockHop)
        end
        add_path(historic_revtr, :historic_revtr, node2names, node2pingable, node2historicallypingable, node2othervpscanreach,symmetric_revtr_links, non_symmetric_revtr_links, node2neighbors, edge_seen_in_measurements, node2asn, oooo_marker)
        # dave returns a symbol if the revtr request failed... TODO: this
        # filtering should happen at a higher level
        add_path(revtr, :revtr, node2names, node2pingable, node2historicallypingable,node2othervpscanreach, symmetric_revtr_links, non_symmetric_revtr_links, node2neighbors, edge_seen_in_measurements, node2asn, oooo_marker) unless revtr[0].is_a?(Symbol)

        upstream_reverse_paths.each do |target, revtr|
            add_path(revtr, :aux_revtr, node2names, node2pingable, node2historicallypingable, node2othervpscanreach,symmetric_revtr_links, non_symmetric_revtr_links, node2neighbors, edge_seen_in_measurements, node2asn, oooo_marker)
        end

        node2names.each_pair do |node,ips|
            node_attributes[node]["label"] = ips.uniq.sort.join(" ").gsub(" ", "\\n")
        end

        node2pingable.each_pair do |node, pingable|
            if !pingable && !node2othervpscanreach[node]
                node_attributes[node]["style"] = "dotted" 
            elsif !pingable && node2othervpscanreach[node]
                node_attributes[node]["style"] = "dashed"
            end # else, use rounded
        end

        node2historicallypingable.each_pair do |node, pingable|
            node_attributes[node]["shape"] = "box" if pingable == "N/A"
            node_attributes[node]["shape"] = "diamond" if !pingable
        end

        symmetric_revtr_links -= non_symmetric_revtr_links

        assign_colors!(node2asn, node_attributes)

        @logger.debug "node2pingable: #{node2pingable.inspect}"
        @logger.debug "node2historicallypingable: #{node2historicallypingable.inspect}"

        output_dot_file(src, dst, direction, dataset, node_attributes, edge_attributes,
                        symmetric_revtr_links, node2neighbors, edge_seen_in_measurements, output)
    end

    private

    def assign_colors!(node2asn, node_attributes)
        all_ases = node2asn.values.uniq
        asn2color = {}
        i = 0
        all_ases.each do |asn|
           next if asn.nil?     # nil asn's get assigned to black by default
           asn2color[asn] = DotGenerator::Colors[i] 
           i += 1
           raise "too many asns!" if i >= DotGenerator::Colors.size
        end

        node2asn.each do |node, asn|
            node_attributes[node]["color"] = asn2color[asn] unless asn.nil?
        end
    end
    
    def add_path(path, type, node2names, node2pingable, node2historicallypingable,
                     node2othervpscanreach, symmetric_revtr_links, non_symmetric_revtr_links,
                     node2neighbors, edge_seen_in_measurements, node2asn, oooo_marker)
        return if !path.valid?
        previous = nil
        current = nil
        for hop in path
          # we include the preamble of the reverse traceroute output as a "hop" -- make sure to exclude
          # preamble from the graph. 
          # Actually, this might be covered by !path.valid? above..
          next if hop.is_a?(ReverseHop) && !hop.valid_ip

          previous = current
          ip = hop.ip
          ip += oooo_marker.next! if ip == "0.0.0.0"
          current = $ip2cluster[ip]
          name = (hop.dns.nil? or hop.dns.empty?) ? hop.ip : hop.dns
          node2names[current] << name
          node2asn[current] = hop.asn
          node2pingable[current] ||= hop.ping_responsive

          node2othervpscanreach[current] ||= hop.reachable_from_other_vps
          
          # TODO: distinguish between a hop being historically unresponsive
          # (hop.last_responsive.nil?) from a hop not found in the pingability
          # DB (hop.last_responsive == "N/A")
          #
          #
          # oh boy, this is messy. Mixing booleans with "N/A" is bad news
          # bears. We need the boolean ||= b/c multiple IPs may map to the same
          # cluster
          in_db = hop.last_responsive != "N/A"
          if !in_db and !node2historicallypingable.include? current
              node2historicallypingable[current] = "N/A"
          elsif in_db and node2historicallypingable[current] != "N/A"
              node2historicallypingable[current] ||= hop.last_responsive
          elsif in_db and node2historicallypingable[current] == "N/A"
              node2historicallypingable[current] = hop.last_responsive
          end

          if previous
            if hop.is_a?(ReverseHop)
              # we annotate reverse links where symmetry was assumed
              raise "not a string! hop.type.class=#{hop.type.class}" unless hop.type.is_a?(Symbol) or hop.type.is_a?(String) or hop.type.nil?
              hop.type = hop.type.to_sym unless hop.type.nil?
              
              if hop.type == :sym 
                symmetric_revtr_links.add [current, previous] 
              else
                non_symmetric_revtr_links.add [current, previous]
              end

              node2neighbors[current][previous] = true
              edge_seen_in_measurements[[current, previous, type]] = true
            else
              node2neighbors[previous][current] = true
              edge_seen_in_measurements[[previous, current, type]] = true
            end
          end
        end
    end
    
    # TODO: is there a way to generate a .jpg without having to write to a file?
    # I'm sure there is some library for interfacing directly with dot...
    def output_dot_file(src, dst, direction, dataset, node_attributes, edge_attributes, symmetric_revtr_links, node2neighbors, edge_seen_in_measurements, dotfn)
        File.open( dotfn, "w"){ |dot|
          dot.puts "digraph \"tr\" {"
          dot.puts "  label = \"#{src}, #{dst}\\n#{direction} failure\\nDataset: #{dataset}\""
          dot.puts "  labelloc = \"t\""
          node_attributes.each_pair do |node,attributes|
            n="  \"#{node}\" ["
            attributes.each_pair{|k,v|
              n << "#{k}=\"#{v}\", "
            }
            n[-2..-1]="];"
            dot.puts n
          end
          node2neighbors.each_pair do |node,neighbors|
            neighbors.each_key do |neighbor|
              edge= "  \"#{node}\" -> \"#{neighbor}\" ["
              attributes = ""
              edge_attributes[[node,neighbor]].each_pair{|k,v|
                attributes += "#{k}=\"#{v}\", " 
              }
              edge = edge + attributes
              if edge_seen_in_measurements[[node,neighbor,:tr]]
                tre=edge
                tre += "style=\"solid\", "
        #        if not edge_attributes[[node,neighbor]].has_key?("style")
        #          tre += "style=\"dotted\", "
        #        end
                tre[-2..-1]="];" 
                dot.puts tre
              end
              if edge_seen_in_measurements[[node,neighbor,:spoofed_tr]]
                tre=edge
                tre += "color=\"blue\",style=\"solid\"];"
                dot.puts tre
              end
              if edge_seen_in_measurements[[node,neighbor,:aux_tr]]
                tre=edge
                tre += "color=\"darkolivegreen\",style=\"solid\"];"
                dot.puts tre
              end
              if edge_seen_in_measurements[[node,neighbor,:historic_tr]]
                tre=edge
                tre += "style=\"dotted\"];"
                dot.puts tre
              end
              if edge_seen_in_measurements[[node,neighbor,:revtr]]
                rtre = edge
                rtre += "color=\"red\", arrowhead=\"none\", arrowtail=\"normal\", "
                if symmetric_revtr_links.include? [node,neighbor]
                    rtre += "label=\"sym\", "
                end

                rtre[-2..-1]="];" 
                dot.puts rtre
              end
              if edge_seen_in_measurements[[node,neighbor,:aux_revtr]]
                rtre = edge
                rtre += "color=\"pink\", arrowhead=\"none\", arrowtail=\"normal\", "
                if symmetric_revtr_links.include? [node,neighbor]
                    rtre += "label=\"sym\", "
                end

                rtre[-2..-1]="];" 
                dot.puts rtre
              end
              if edge_seen_in_measurements[[node,neighbor,:historic_revtr]]
                rtre = edge
                rtre += "style=\"dotted\", color=\"red\", arrowhead=\"none\", arrowtail=\"normal\", "
                if symmetric_revtr_links.include? [node,neighbor]
                    rtre += "label=\"sym\", "
                end

                rtre[-2..-1]="];" 
                dot.puts rtre
              end
            end
          end
          dot.puts "}"
        }
    end
end

if $0 == __FILE__

#    ipInfo = IpInfo.new
#    tr = [[1, "0.0.0.0"], [2, "0.0.0.0"], [3, "192.5.89.222"], [4,"216.27.100.53"], [5, "216.27.100.74"],
#          [6, "128.91.10.3"], [7, "158.130.128.1"], [8, "158.130.6.253"]].map { |hop| ForwardHop.new(hop, ipInfo) }
#
#    spoofed_tr = [[1, ["75.130.96.1"]], [2, ["192.5.89.241"]], [3, ["192.5.89.222"]], [4,["216.27.100.53"]], [5, ["216.27.100.74"]],
#          [6, ["128.91.10.3"]], [7, ["158.130.128.1"]], [8,["158.130.6.253"]]].map { |hop| SpoofedForwardHop.new(hop, ipInfo) }
#
#    historic_tr = [[1, "0.0.0.0"], [2, "192.5.89.241"], [3, "192.5.89.222"], [4,"216.27.100.53"], [5, "216.27.100.74"],
#          [6, "128.91.10.3"], [7, "158.130.128.1"], [8, "158.130.6.253"]].map { |hop| HistoricalForwardHop.new(hop[0], hop[1], ipInfo) }
#
#    # TODO: historic_tr.each do { |hop| hop.reverse_path = blah blah }
#
#    revtr = ["0 planetlab2.cis.UPENN.EDU (158.130.6.253) * dst ",
#    "1 external2-border-router.seas.upenn.edu (158.130.128.1) * sym ",
#    "2 vag2-core1.dccs.upenn.edu (128.91.9.3) * rr ",
#    "3 external3-core1.dccs.UPENN.EDU (128.91.9.2) * tr ",
#    "4 external-core1.dccs.upenn.edu (128.91.9.1) * -tr ",
#    "5 local.upenn.magpi.net (216.27.100.73) * -tr ",
#    "6 remote.internet2.magpi.net (216.27.100.54) * -tr ", 
#    "7 nox300gw1-vl-110-nox-internet2.nox.org (192.5.89.221) * -tr ", 
#    "8 nox300gw1-peer-nox-wpi-192-5-89-242.nox.org (192.5.89.242) * -tr ",
#    "9 PLANETLAB1.RESEARCH.WPI.NET (75.130.96.12) * -tr "].map { |hop| ReverseHop.new(hop, ipInfo) }
#
#    historic_revtr = ["0 planetlab2.cis.UPENN.EDU (158.130.6.253) * dst ",
#    "1 external2-border-router.seas.upenn.edu (158.130.128.1) * sym ",
#    "2 vag2-core1.dccs.upenn.edu (128.91.9.3) * rr ",
#    "3 external3-core1.dccs.UPENN.EDU (128.91.9.2) * tr ",
#    "4 external-core1.dccs.upenn.edu (128.91.9.1) * -tr ",
#    "5 local.upenn.magpi.net (216.27.100.73) * -tr ",
#    "6 remote.internet2.magpi.net (216.27.100.54) * -tr ", 
#    "7 nox300gw1-vl-110-nox-internet2.nox.org (192.5.89.221) * -tr ", 
#    "8 nox300gw1-peer-nox-wpi-192-5-89-242.nox.org (192.5.89.242) * -tr ",
#    "9 PLANETLAB1.RESEARCH.WPI.NET (75.130.96.12) * -tr "].map { |hop| ReverseHop.new(hop, ipInfo) }
#
#    Dot::generate_jpg("PLANETLAB1.RESEARCH.WPI.NET", "planetlab2.cis.UPENN.EDU (158.130.6.253)",
#        "forward path", "Routers on paths beyond Harsha's PoPs", tr, spoofed_tr, historic_tr, revtr, historic_revtr, ARGV.shift)

    require 'log_iterator' 
    d = DotGenerator.new
    LogIterator::read_log_rev4(FailureIsolation.IsolationResults+"/plgmu4.ite.gmu.edu_77.221.192.1_2011224142939.bin") do |outage|
       d.generate_jpg(outage.src, outage.dst, outage.direction, outage.dataset, outage.tr, outage.spoofed_tr, outage.historical_tr, outage.spoofed_revtr, outage.historical_revtr, "testing.jpg")
    end
end
