#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")
$: << File.expand_path("../../")

require 'log_iterator'
require 'log_filterer'
require 'filters'
require 'ip_info'
require 'mkdot'
require 'fileutils'
require 'isolation_mail'
require 'outage'

dot_gen = DotGenerator.new
options = OptsParser.new([Predicates.PassedFilters, Predicates.MeasurementComplete]).parse!.display
ip_info = IpInfo.new

id = 0
LogIterator.iterate_all_logs(options) do |o|
    # Recompute filters... (we loosened the rules before SIGCOMM)
    SecondLevelFilters.filter!(o, FilterTracker.new(o.src,o.dst,o.connected,o.time), ip_info)
    next unless o.passed?

    o.connected ||= [] 
    o.formatted_connected ||= []
    o.formatted_unconnected ||= []
    o.formatted_never_seen ||= []

    jpg = "/homes/network/revtr/www/isolation_graphs/potential_cases/jpgs/#{File.basename(o.file)}.jpg"
    puts jpg
    dot_gen.generate_jpg(o,jpg)
    #begin
    #    merged_outage = MergedOutage.new(id+=1, [o])
    #    if o.src == "pl1.rcc.uottowa.ca"
    #        Emailer.isolation_results(merged_outage).deliver
    #    elsif o.src == "planetlab2.csohio.edu"
    #        Emailer.isolation_results(merged_outage).deliver
    #    end
    #rescue Exception => e
    #    $stderr.puts "Exception: #{e} #{e.backtrace} #{o.file}"
    #end
end
