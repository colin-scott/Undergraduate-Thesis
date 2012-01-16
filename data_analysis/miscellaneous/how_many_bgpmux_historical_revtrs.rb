#!/homes/network/revtr/ruby-upgrade/bin/ruby

require 'revtr_cache_interface'
require 'failure_isolation_consts'

cache = RevtrCache.new

FailureIsolation::PoisonerNames.each do |poisoner|
    FailureIsolation.TargetSet.each do |target|
        path = cache.get_cached_reverse_path(poisoner, target)
        puts "#{poisoner} #{target} #{path.valid?} #{path.invalid_reason}"
    end
end
