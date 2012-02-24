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
    if not outage_id.include? "/"
        outage_id = FailureIsolation::IsolationResults + "/#{outage_id}"
    end
    o = nil
    begin
        o = LogIterator.read_log(outage_id)
    rescue
        # Not sure why the id was screwed up? had one too many .bin extensions
        file = outage_id.gsub(/.bin$/, "")
        o = LogIterator.read_log(file)
    end

    extension = 'png'
    basename = "#{File.basename(o.file)}.#{extension}"
    img_output = "/homes/network/revtr/www/isolation_graphs/ethan_testing/#{basename}"
    dot_gen.generate_png(o, img_output)
    puts "image output at: http://revtr.cs.washington.edu/isolation_graphs/ethan_testing/#{basename}"
    puts "image output at: /homes/network/revtr/www/isolation_graphs/ethan_testing/#{basename}"
    puts "no_legend output at: /homes/network/revtr/www/isolation_graphs/ethan_testing/#{basename.gsub(/\.#{extension}$/, "_no_legend.#{extension}")}"
    puts "dot output at: /homes/network/revtr/www/isolation_graphs/ethan_testing/#{basename.gsub(/\.#{extension}$/, '.dot')}"
end
