#!/homes/network/revtr/ruby-upgrade/bin/ruby

require 'isolation_module'


puts `#{FailureIsolation::CachedRevtrTool} #{ARGV.shift} #{ARGV.shift}`.split("\n").inspect
