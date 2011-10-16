#! /usr/bin/ruby
$: << File.expand_path("../")
require "reverse_traceroute"
configfn="/homes/network/ethan/timestamp/reverse_traceroute/reverse_traceroute/config_zooter.rb"
set_cover="/homes/network/ethan/timestamp/reverse_traceroute/data/set_cover_prefix_results.txt"
require configfn
DRb.start_service
$log_probes=false

revtrs=[]
dir="/tmp/ts_test"
if ARGV.length>1
	dir=ARGV[1]
end
File.open(ARGV[0], "r"){|f|
	f.each_line{|pair|
		src,dst=pair.chomp("\n").split(" ")
		revtrs << ReverseTraceroute.new(src,dst)
	}
}
no_hops=revtrs
reached=[]
found_hops=[]
no_vps=[]
no_adj=[]
while not no_hops.empty? 
	r, f, no_hops, v, a = reverse_hops_ts(no_hops,dir)
	reached += r
	found_hops += f
	no_vps += v
	no_adj += a
end

$LOG.puts "REACHED"
reached.each{|x| $LOG.puts x.curr_path.to_s(true)}
$LOG.puts "FOUND"
found_hops.each{|x| $LOG.puts x.curr_path.to_s(true)}
$LOG.puts "NONE"
no_hops.each{|x| $LOG.puts x.curr_path.to_s(true)}
$LOG.puts "NO VPS"
no_vps.each{|x| $LOG.puts x.curr_path.to_s(true)}
$LOG.puts "NO ADJ"
no_adj.each{|x| $LOG.puts x.curr_path.to_s(true)}
