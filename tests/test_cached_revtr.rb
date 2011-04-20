#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'isolation_module'


puts `#{FailureIsolation::CachedRevtrTool} #{ARGV.shift} #{ARGV.shift}`.split("\n").inspect
