#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'drb'
require 'isolation_module'
require 'failure_dispatcher'
require 'outage'
require 'hops'

Thread.abort_on_exception = true
require 'utilities'
$LOG = LoggerLog.new($stderr)

dispatcher = FailureDispatcher.new

hosts = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri).hosts.sort_by { rand }.clone
src = hosts.shift
dst_hostname = hosts.shift
dst = $pl_host2ip[dst_hostname]

receivers = hosts[0..5]

o = Outage.new(src, dst, receivers, [], [])
o.dst_hostname = dst_hostname
o.src_ip = $pl_host2ip[src]
o.symmetric = true
o.direction = Direction::FORWARD

fake_path = [Hop.new("128.208.2.102"), Hop.new("216.239.46.212"),
                   Hop.new("66.249.94.201"), Hop.new("66.249.94.201")]

asn = 1
fake_path.each do |h|
    h.asn = asn
    asn += 1
end

o.tr = ForwardPath.new(fake_path.clone)

ingress = Hop.new("64.233.174.129")
ingress.asn = 999
fake_path[-1] = ingress
fake_path << Hop.new("1.2.3.4")

o.historical_tr = ForwardPath.new(fake_path.clone)

dispatcher.splice_alternate_paths(o)

raise "spliced paths empty" if o.spliced_paths.empty?
raise "not correct ingress" if o.spliced_path[0].ingress == ingress

$stderr.puts o.spliced_paths.inspect
