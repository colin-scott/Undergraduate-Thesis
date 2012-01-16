#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../../")

# SEEMS HIGHLY REDUNDANT WITH OTHER SCRIPTS IN THIS DIR

require 'isolation_module'
require 'utilities'
require 'failure_analyzer'
require 'failure_dispatcher'
require 'log_iterator'
require 'ip_info'
require 'set'
require 'fileutils'
require 'suspect_set_processors'
require 'db_interface'

date = Time.utc(2011, 8, 25)

analyzer = FailureAnalyzer.new

def no_pings?(m)
        in_count = 0
        removed = []

        m.pruner2incount_removed.each do |p, incount_removed|
            next if p == "intersecting_traces_to_src"
            in_count += incount_removed[0]
            removed += incount_removed[1]
        end

        removed.size == 0
end

@db = DatabaseInterface.new
@logger = LoggerLog.new($stderr)

def intersecting_traces_to_src(merged_outage, path)
        to_remove = []
        merged_outage.each do |o|
            # select all hops on current traceroutes where destination is o.src
            site = FailureIsolation.Host2Site[o.src]
            @logger.warn "intersecting_traces_to_src, site nil! #{o.src}" if site.nil?
            hops_on_traces = FailureIsolation.hops_on_pl_pl_traces_to_site(@db, site, path) unless site.nil?
            if hops_on_traces.empty?
                @logger.warn "no hops on traces to site: #{site}"
            else
                @logger.info "found intersecting hops on traces to site: #{site}"
            end

            to_remove += hops_on_traces
        end

        return to_remove
end


LogIterator::merged_iterate do |m|
    next unless m.is_interesting?
    next unless m.merging_method == MergingMethod::REVERSE
    next unless m.direction == Direction.REVERSE

    next if !m.time
    next if m.time < date

    # put back in new historical hops!
    ip2suspects = Hash.new { |h,k| h[k] = [] }
    analyzer.initialize_suspect_set(m, ip2suspects)

    out_dir = "/homes/network/revtr/spoofed_traceroute/reverse_traceroute/data_analysis/arvind/all_reverse_path_correlations/#{m.sources.join('_')}_#{m.destinations[0..5].join('_')}"
    FileUtils.mkdir_p(out_dir)

    Dir.chdir(out_dir) do 
        File.open("src_dst_pairs.txt", "w") do |f|
            m.outages.each do |o|
                f.puts "#{o.to_s(true)} #{o.direction} #{o.dataset}"
            end
        end

        path =  FailureIsolation.pl_pl_path_for_date(m.time) 
        File.open("path_to_current_traces", "w") { |f| f.puts path }

        current_traces_to_source = intersecting_traces_to_src(m, path)
        File.open("current_trs_to_src_pruner", "w") { |f| f.puts current_traces_to_source.to_a.join("\n") }

        m.initializer2suspectset.each do |init, suspect_set|
            File.open(init, "w") { |f| f.puts suspect_set.to_a.map { |s| s.is_a?(String) ? s : s.ip }.join("\n") }
        end

        in_count = 0
        removed = []

        m.pruner2incount_removed.each do |p, incount_removed|
            next if p == "intersecting_traces_to_src"
            in_count += incount_removed[0]
            removed += incount_removed[1]
        end

        File.open("pings_from_source_#{in_count}", "w") { |f| f.puts removed.join("\n") }

        remaining_suspects = m.initializer2suspectset.value_set.to_a.map { |s| (s.is_a?(String)) ? s : s.ip } - removed 

        #File.open("remaining_suspect_set.txt", "w") { |f| f.puts remaining_suspects.join("\n") }
    end

    puts "#{FailureIsolation::MergedIsolationResults}/#{m.file}.bin"
end 
