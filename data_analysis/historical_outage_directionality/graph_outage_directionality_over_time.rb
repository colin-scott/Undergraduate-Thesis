#!/homes/network/revtr/jruby/bin/jruby

$: << "/homes/network/revtr/spoofed_traceroute/reverse_traceroute"
$: << "/homes/network/revtr/spoofed_traceroute/reverse_traceroute/data_analysis"

require 'isolation_module'
require 'failure_isolation_consts.rb'
require 'failure_analyzer'
require 'failure_dispatcher'
require 'filter_stats'
require 'ip_info'
require 'set'
require 'yaml'
require 'time'
require 'log_iterator.rb'
require 'log_filterer.rb'

options = OptsParser.new
options.set_predicates([Predicates.PassedFilters])
options[:time_start] = Time.at(0)
options.parse!.display

# per week, per day, per month?
# Let's go with per week
week2forward = Hash.new(0)
week2reverse = Hash.new(0)
week2bi = Hash.new(0)
week2total = Hash.new(0)

LogIterator::iterate_all_logs(options) do |o|
    time = o.time
    #next unless time
    
    o.direction = (o.direction.is_a?(String)) ? BackwardsCompatibleDirection.convert_to_new_direction(o.direction) : o.direction

    # Year, week number of current year
    week = time.strftime("%Y.%U")

    case o.direction
    when Direction.FORWARD
        week2forward[week] += 1
    when Direction.REVERSE
        week2reverse[week] += 1
    when Direction.BOTH
        week2bi[week] += 1
    end

    week2total[week] += 1
end

week2forwardoutput = File.open("forward.txt", "w") { |f| f.puts week2forward.to_a.sort_by {|elt| elt[0] }.map { |elt| elt.join ' '}.join "\n" } 
week2reverseoutput = File.open("reverse.txt", "w") { |f| f.puts week2reverse.to_a.sort_by {|elt| elt[0] }.map { |elt| elt.join ' '}.join "\n" } 
week2bioutput = File.open("bidirectional.txt", "w") { |f| f.puts week2bi.to_a.sort_by {|elt| elt[0] }.map { |elt| elt.join ' '}.join "\n" } 
week2totaloutput = File.open("total.txt", "w") { |f| f.puts week2total.to_a.sort_by {|elt| elt[0] }.map { |elt| elt.join ' '}.join "\n" } 

