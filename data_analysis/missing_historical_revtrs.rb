#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'

LogIterator::iterate do  |o|
    if !o.historical_revtr.valid?
        puts o.file
        puts o.historical_revtr
    end
end
