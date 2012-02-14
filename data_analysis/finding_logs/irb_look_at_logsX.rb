#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../../")
$: << File.expand_path("../")

require 'outage'
require 'irb'
require 'log_iterator'

File.foreach(ARGV.shift) do |file|
    file = (file.include? "isolation_results") ? file : "#{FailureIsolation::IsolationResults}/#{file}"
    file = file.chomp
    $o = LogIterator.read_log(file)
    IRB.start
end
