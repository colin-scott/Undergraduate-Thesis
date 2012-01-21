#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../../")

require 'outage'
require 'irb'
require 'mkdot'

$d = DotGenerator.new

File.foreach(ARGV.shift) do |file|
    file = (file.include? "isolation_results") ? file : "#{FailureIsolation::IsolationResults}/#{file}"
    $o = Marshal.load(File.open(file.chomp))
    #IRB.start
    $d.generate_jpg($o)
end
