#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../../")
$: << File.expand_path("../")

require 'outage'
require 'failure_isolation_consts'
require 'log_iterator'
require 'mkdot'

if ARGV.empty?
    $stderr.puts "Usage: #{$0} <outage id> [<outage id> ... <outage id>]"
    exit
end

dot_gen = DotGenerator.new
outage_ids = ARGV.clone

outage_ids.each do |outage_id|
    o = nil
    begin
        o = LogIterator.read_log(outage_id)
    rescue
        # Not sure why the id was screwed up? had one too many .bin extensions
        file = outage_id.gsub(/.bin$/, "")
        o = LogIterator.read_log(file)
    end

    basename = "#{File.basename(o.file)}.jpg"
    jpg_output = "/homes/network/revtr/www/isolation_graphs/ethan_testing/#{basename}"
    dot_gen.generate_jpg(o, jpg_output)
    puts "jpg output at: http://revtr.cs.washington.edu/isolation_graphs/ethan_testing/#{basename}"
    puts "jpg output at: /homes/network/revtr/www/isolation_graphs/ethan_testing/#{basename}"
    puts "jpg_no_legend output at: /homes/network/revtr/www/isolation_graphs/ethan_testing/#{basename.gsub(/\.jpg$/, '_no_legend.jpg')}"
    puts "dot output at: /homes/network/revtr/www/isolation_graphs/ethan_testing/#{basename.gsub(/\.jpg$/, '.dot')}"
end
