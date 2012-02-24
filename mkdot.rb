#!/homes/network/revtr/ruby-upgrade/bin/ruby

# Module for generating DOT graphs for human consumption of measurement data.

# TODO:
#    * Use ruby's dot gem rather than manipulating the dot output manually.
#    * This code is shite. Refactor just about everything. esp. add_path()
#    * handle 0.0.0.0's more elegantly. To collapse too many 0.0.0.0's, what if we name the 0.0.0.0
#       nodes as the hop before them and the hop after them, and say the number of *s in a row? this
#       would collapse these cases while keeping distinct ones that should be distinct
#    * For paths that don't reach, should we connect them to the dst / src, with a special edge indicating 
#        that it didn't work? This will tie the images together.
#    * use a different alias dataset
#    * fix the bug where there are gaps in the spoofed traceroute ttls ->
#         false edges

require 'hops'
require 'set'
require 'ip_info'
require 'resolv'
require 'isolation_utilities.rb'

$ip2cluster ||= Hash.new { |h,k| k } # loaded by isolation_module.rb

class DotGenerator
    def initialize(logger = LoggerLog.new($stderr), isp2asn_fn=$ASN_TO_ISP_MAP, ip_info=IpInfo.new)
        @logger = logger
        @asn2isp = load_asn_to_isp_map(isp2asn_fn)
        @ip_info = ip_info
    end

    # Give unique colors to each isp
    DotGenerator::Colors = ["aquamarine",  "blue", "blueviolet", "brown", "cadetblue", "chartreuse", "chocolate", "coral", "cornflowerblue", "crimson", "cyan", "darkgoldenrod1", "darkgreen", 
                     "darkolivegreen", "darkorange", "darkorchid", "darkslateblue", "forestgreen", "deeppink1", "firebrick1", "gold", "green", "indigo", "midnightblue", "red", 
                     "saddlebrown", "violetred1", "springgreen", "bisque"]

    # fn is CSV: ASN,ISP name
    # map to string to string, to deal with 32-bit asns
    def load_asn_to_isp_map(fn)
        asn2isp = Hash.new{|h,k| h.include?(k.to_s)? h[k.to_s] : k}
        File.open(fn, 'r'){|f|
            f.each{|line|
                # TODO(ethankb): make this a regexp that is passed in to allow
                # either file format.  low priority
                info = line.chomp("\n").split(",")
                asn2isp[info[0]] = info[1..-1].join(",")
#                 info = line.chomp("\n").split(",")
#                 info[1..-1].each{|asn|
#                     $stderr.puts "#{asn} #{info[0]}"
#                     asn2isp[asn] = info[0]
#                 }
            }
        }
        return asn2isp
    end
        
    # Top level method for generating a DOT graph
    # Generates a jpg with a legend.  Also generates put and legend-less files
    # in the same directory with similar names, in case we need to edit the
    # dot by hand (pruning, say) or move the legend to a different location.
    def generate_jpg(outage, output="/tmp/t.jpg", legend_fn=$DOT_LEGEND_FN)
        generate_image(outage, output, legend_fn, extension='jpg')
#         raise "Output file must be a .jpg!" unless output =~ /\.jpg$/
#         dot_output = output.gsub(/\.jpg$/, ".dot")
#         create_dot_file(outage, dot_output)
#         no_legend = output.gsub(/\.jpg$/, '_no_legend.png')
#         system "dot -Tpng:cairo #{dot_output} > #{no_legend}"
#         system "composite -gravity northeast #{legend_fn} #{no_legend} #{output.gsub(/\.jpg$/, ".png")}"
    end

    def generate_png(outage, output="/tmp/t.jpg", legend_fn=$DOT_LEGEND_FN)
        generate_image(outage, output, legend_fn, extension='png')
    end

    def generate_image(outage, output="/tmp/t.jpg", legend_fn=$DOT_LEGEND_FN,
                       extension='jgp')
        raise "Output file must be a .#{extension}!" unless output =~ /\.#{extension}$/
        dot_output = output.gsub(/\.#{extension}$/, ".dot")
        create_dot_file(outage, dot_output)
        no_legend = output.gsub(/\.#{extension}$/, "_no_legend.#{extension}")
        system "dot -T#{extension}:cairo #{dot_output} > #{no_legend}"
        system "composite -gravity northeast #{legend_fn} #{no_legend} #{output}"
    end

    # helper method. create the dot file, in preparation for the final jpg
    def create_dot_file(outage, output)
        # TODO: fix the references so we don't have to type this out
        src = outage.src
        dst = outage.dst
        direction = outage.direction
        dataset = outage.dataset
        tr = outage.tr
        spoofed_tr = outage.spoofed_tr
        historic_tr = outage.historic_tr
        revtr = outage.revtr
        historic_revtr = outage.historic_revtr
        additional_traces = outage.additional_traces
        upstream_reverse_paths = outage.upstream_reverse_paths
        upstream_reverse_paths ||= []

        # we want to keep all 0.0.0.0's distinct in the final graph, so
        # we append this marker to each 0.0.0.0 node to keep them distinct
        # TODO: find a better way to keep 0.0.0.0's distinct
        oooo_marker = "a" 

        # the source is not included in the forward traceroutes, so we insert
        # a mock hop object into the beginning of the paths
        src_ip = $pl_ip2host[src]
        src_ip = (Resolv.getaddress(src) rescue src) unless src_ip.matches_ip?
        src_ip = "0.0.0.0" unless src_ip.matches_ip?
        src_hop = Hop.new(src_ip, src, @ip_info)
        tr = ForwardPath.new(src, dst, [src_hop] + tr)
        spoofed_tr = ForwardPath.new(src, dst, [src_hop] + spoofed_tr)
        historic_tr = ForwardPath.new(src, dst, [src_hop] + historic_tr)

        if historic_revtr.valid? and historic_revtr[0].ip != dst
            dst_hop = Hop.new(dst, @ip_info)
            historic_revtr = HistoricalReversePath.new(dst, src, [dst_hop] +  historic_revtr)
        end

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
        
        # cluster -> Set of clusters
        node2neighbors=Hash.new{|hash,key| hash[key] = Set.new }
        
        # Set of [cluster,cluster,measurement_type]
        # whether it was seen in, say, traceroutes
        edge_seen_in_measurements = Set.new

        # cluster -> pingable?
        node2pingable = {}

        # cluster -> historically pingable?
        node2historicallypingable = Hash.new(false)

        # set of all isps
        # as of 2012/2/18, this actually stores node->ISP name, rather than
        # node->ASN
        node2isp = {}

        # is a node not pingable from S, but pingable from other VPs?
        node2othervpscanreach = {}

        # Inputs to add_path
        symbol2paths = {
            :tr => [tr],
            :aux_tr => additional_traces,
            :spoofed_tr => [spoofed_tr],
            :historic_tr => [historic_tr],
            :historic_revtr => [historic_revtr] + historic_tr.map { |hop| hop.reverse_path }.find_all { |path| !path.is_a?(Array) },
            :revtr => [revtr],
            :aux_revtr => upstream_reverse_paths
        }

        # Add invisible links for forward trs that didn't reach in add_path()
        dst_node = $ip2cluster[dst] 

        # Add paths
        symbol2paths.each do |symbol, paths|
            paths.each do |path|
                add_path(path, symbol, dst_node, node2names, node2pingable, node2historicallypingable,
                         node2othervpscanreach, symmetric_revtr_links, non_symmetric_revtr_links,
                         node2neighbors, edge_seen_in_measurements, edge_attributes, node2isp, oooo_marker)
            end
        end

        
        # Add labels
        node2names.each_pair do |node,ips|
            node_attributes[node]["label"] = ips.uniq.sort.map { |ip| ip.gsub(/0.0.0.0/, "*") }.join(" ").gsub(" ", "\\n")
        end

        # Classify Reachability
        node2pingable.each_pair do |node, pingable|
            if !pingable && !node2othervpscanreach[node]
                node_attributes[node]["style"] = "dotted" 
            elsif !pingable && node2othervpscanreach[node]
                node_attributes[node]["style"] = "dashed"
            end # else, use rounded
        end

        # Classify Historical Reachability
        node2historicallypingable.each_pair do |node, pingable|
            node_attributes[node]["shape"] = "box" if pingable == "N/A"
            node_attributes[node]["shape"] = "diamond" if !pingable
        end

        symmetric_revtr_links -= non_symmetric_revtr_links

        # Assign colors by isp
        isp2color = assign_colors!(node2isp, node_attributes)

        @logger.debug { "node2pingable: #{node2pingable.inspect}" }
        @logger.debug { "node2historicallypingable: #{node2historicallypingable.inspect}" }

        # Dump to file
        output_dot_file(src, dst, direction, dataset, node2isp, node_attributes,
                        edge_attributes, symmetric_revtr_links, node2neighbors,
                        edge_seen_in_measurements, output, isp2color)
    end

    private

    def assign_colors!(node2isp, node_attributes)
        all_isps = node2isp.values.uniq
        isp2color = {}
        i = 0
        all_isps.each do |isp|
           next if isp.nil?     # nil isp's get assigned to black by default
           isp2color[isp] = DotGenerator::Colors[i] 
           i += 1
           raise "too many isps!" if i >= DotGenerator::Colors.size
        end

        node2isp.each do |node, isp|
            node_attributes[node]["color"] = isp2color[isp] unless isp.nil?
        end
        return isp2color
    end
    
    #
    def add_path(path, type, dst_node, node2names, node2pingable, node2historicallypingable,
                     node2othervpscanreach, symmetric_revtr_links, non_symmetric_revtr_links,
                     node2neighbors, edge_seen_in_measurements, edge_attributes, node2isp, oooo_marker)
        if !path.respond_to?(:valid?) 
            raise "Not a path object #{path.class} #{type}" 
        end
        return if !path.valid?
        previous = nil
        current = nil
        for i in (0...path.size)
          hop = path[i]
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
          node2isp[current] = @asn2isp[hop.asn]
          node2pingable[current] ||= hop.ping_responsive

          node2othervpscanreach[current] ||= hop.reachable_from_other_vps
          
          # TODO: distinguish between a hop being historically unresponsive
          # (hop.last_responsive.nil?) from a hop not found in the pingability
          # DB (hop.last_responsive == "N/A")
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

              node2neighbors[current].add previous
              edge_seen_in_measurements.add [current, previous, type]
            else
              node2neighbors[previous].add current
              edge_seen_in_measurements.add [previous, current, type]
            end
          end

          ## Add in invisble link if the trace didn't reach
          # (This code needs to stay in add_path(), since current may be a
          # 0.0.0.0X node
          if i+1 == path.size and path.valid? and [:tr, :spoofed_tr, :historic_tr].include? type and current != dst_node
            node2neighbors[current].add dst_node
            # Note that we give edge_seen_in_measurements a special type, to
            # differentiate from (blue|black|red) 
            edge_seen_in_measurements.add [current, dst_node, :invis]
          end
        end
    end

    
    # TODO: is there a way to generate a .jpg without having to write to a file?
    # I'm sure there is some library for interfacing directly with dot...
    def output_dot_file(src, dst, direction, dataset, node2isp,
                        node_attributes, edge_attributes, symmetric_revtr_links, node2neighbors, edge_seen_in_measurements, dotfn, isp2color)
        File.open( dotfn, "w"){ |dot|
          dot.puts "digraph \"tr\" {"
          dot.puts "  label = \"Src:#{src}, Dst:#{dst}\\n#{direction} failure\\nDataset: #{dataset}\""
          dot.puts "  labelloc = \"t\""
          isp2nodes = Hash.new{|h,k| h[k] = []}
          node2isp.each_pair{|node, isp|
              isp2nodes[isp] << node
          }

          isp2nodes.each_pair{|isp, nodes|
              if not isp.nil?
                dot.puts "subgraph cluster_#{isp.to_s.gsub(/[^0-9a-z]/i, '_')}{"
                dot.puts "  fontsize=\"22\";"
                dot.puts "  labeljust=\"l\";"
                dot.puts "  label=\"#{isp}\";"
                #dot.puts "  label=\"AS#{@asn2isp[asn]}\";"
                dot.puts "  color=\"#{isp2color[isp]}\";"
              end

              nodes.each{|node|
                attributes = node_attributes[node]
                n="  \"#{node}\" ["
                attributes.each_pair{|k,v|
                  n << "#{k}=\"#{v}\", "
                }
                n[-2..-1]="];"
                dot.puts n
              }
              if not isp.nil?
                  dot.puts "}"
              end
          }

          node2neighbors.each_pair do |node,neighbors|
            neighbors.each do |neighbor|
              edge= "  \"#{node}\" -> \"#{neighbor}\" ["
              attributes = ""
              edge_attributes[[node,neighbor]].each_pair{|k,v|
                attributes += "#{k}=\"#{v}\", " 
              }
              edge = edge + attributes
              if edge_seen_in_measurements.include? [node,neighbor,:tr]
                tre=edge
                tre += "style=\"solid\", "
        #        if not edge_attributes[[node,neighbor]].has_key?("style")
        #          tre += "style=\"dotted\", "
        #        end
                tre[-2..-1]="];" 
                dot.puts tre
              end
              if edge_seen_in_measurements.include? [node,neighbor,:spoofed_tr]
                tre=edge
                tre += "color=\"blue\",style=\"solid\"];"
                dot.puts tre
              end
              if edge_seen_in_measurements.include? [node,neighbor,:aux_tr]
                tre=edge
                tre += "color=\"darkolivegreen\",style=\"solid\"];"
                dot.puts tre
              end
              if edge_seen_in_measurements.include? [node,neighbor,:historic_tr]
                tre=edge
                tre += "style=\"dotted\"];"
                dot.puts tre
              end
              if edge_seen_in_measurements.include? [node,neighbor,:revtr]
                rtre = edge
                rtre += "color=\"red\", dir=\"back\", arrowhead=\"none\", arrowtail=\"normal\", "
                if symmetric_revtr_links.include? [node,neighbor]
                    rtre += "label=\"sym\", "
                end

                rtre[-2..-1]="];" 
                dot.puts rtre
              end
              if edge_seen_in_measurements.include? [node,neighbor,:aux_revtr]
                rtre = edge
                rtre += "color=\"pink\", dir=\"back\", arrowhead=\"none\", arrowtail=\"normal\", "
                if symmetric_revtr_links.include? [node,neighbor]
                    rtre += "label=\"sym\", "
                end

                rtre[-2..-1]="];" 
                dot.puts rtre
              end
              if edge_seen_in_measurements.include? [node,neighbor,:historic_revtr]
                rtre = edge
                rtre += "style=\"dotted\", color=\"red\", dir=\"back\", arrowhead=\"none\", arrowtail=\"normal\", "
                if symmetric_revtr_links.include? [node,neighbor]
                    rtre += "label=\"sym\", "
                end

                rtre[-2..-1]="];" 
                dot.puts rtre
              end
              if edge_seen_in_measurements.include? [node,neighbor,:invis]
                rtre = edge
                rtre += "style=\"invis\"];"
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

end
