#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../../")
$: << File.expand_path("../")

require 'failure_isolation_consts'
require 'outage'
require 'irb'
require 'log_iterator'
require 'rubygems'
require 'mkdot'

$dot_gen = DotGenerator.new

outage_ids = ARGV.clone

ARGV = []

outage_ids.each do |outage_id|
    if not outage_id.include? "/"
        outage_id = FailureIsolation::IsolationResults + "/#{outage_id}"
    end
    puts outage_id
    o = nil
    begin
        o = LogIterator.read_log(outage_id)
    rescue Exception => e
        # Not sure why the id was screwed up? had one too many .bin extensions
        file = outage_id.gsub(/.bin$/, "")
        o = LogIterator.read_log(file)
    end

    $o = o
    require 'ruby-debug'
    debugger
    $dot_gen.generate_jpg($o, "/homes/network/revtr/www/isolation_graphs/colin_testing/#{File.basename o.file}.jpg")
end
