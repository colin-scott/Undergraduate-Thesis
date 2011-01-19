#!/homes/network/revtr/ruby/bin/ruby

require 'isolation_module'


puts `#{FailureIsolation::CachedRevtrTool} #{ARGV.shift} #{ARGV.shift}`.split("\n").inspect
