#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../../")

require 'outage'
require 'irb'

raise "Must provide input file" if ARGV.empty?

File.foreach(ARGV.shift) do |file|
    file = (file.include? "isolation_results") ? file : "#{FailureIsolation::MergedIsolationResults}/#{file}"
    $m = Marshal.load(File.open(file.chomp))
    IRB.start
end
