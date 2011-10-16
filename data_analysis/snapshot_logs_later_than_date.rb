#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

# Given a date, copy all logs later than date to the snapshot directory for
# further data analysis.

require 'log_iterator'
require 'data_analysis'
require 'fileutils'
require 'hops'

reference = Time.local(2011, "May", 24)

to_move = []
LogIterator::iterate_all_logs do  |outage|
    if outage.time and outage.time > reference
         to_move << outage.file
    end
end

Dir.chdir FailureIsolation::Snapshot do
   FileUtils.rm(Dir.glob("*"))
end

#File.open("to_move.txt", "w") { |f| f.puts to_move.join "\n" }

to_move.map! { |file| "#{file}.bin" }

Dir.chdir FailureIsolation::IsolationResults do
   FileUtils.cp(to_move, FailureIsolation::Snapshot) 
end
