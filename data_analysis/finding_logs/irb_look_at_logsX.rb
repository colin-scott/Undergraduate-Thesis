#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../../")

require 'outage'
require 'irb'


File.foreach(ARGV.shift) do |file|
    file = (file.include? "isolation_results") ? file : "#{FailureIsolation::IsolationResults}/#{file}"
    $o = Marshal.load(File.open(file.chomp))
    IRB.start
end
