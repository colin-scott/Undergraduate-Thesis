#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../../")

require 'outage'
require 'irb'

raise "Must provide input file" if ARGV.empty?

i = IpInfo.new

File.foreach(ARGV.shift) do |file|
    file = (file.include? "isolation_results") ? file : "#{FailureIsolation::MergedIsolationResults}/#{file}"
    $m = Marshal.load(File.open(file.chomp))
    $m.suspected_failures.each do |dir,set|
        hop = set.find { |h| i.getASN(h.ip) == ARGV.shift }
        if hop
            puts "YIPEE"
            puts hop.inspect
            exit
        end
    end
end

puts "bOO"

