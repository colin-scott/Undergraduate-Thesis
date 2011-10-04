#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'direction'
require 'outage'
require 'hops'
require 'poisoner'

require 'ip_info'

require 'utilities'
Thread.abort_on_exception = true

p = Poisoner.new
outage1 = Marshal.load(IO.read("mlab1.ath01.measurement-lab.org_193.138.215.1_20110921081833.bin"))
outage2 = Marshal.load(IO.read("mlab1.ath01.measurement-lab.org_193.200.159.1_20110921081829.bin"))

outage1.src = "prin.bgpmux"
outage2.src = "UWAS.BGPMUX"

outage1.direction = Direction.REVERSE
outage2.direction = Direction.BOTH

outage1.passed_filters = true
outage2.passed_filters = true

ip_info = IpInfo.new
outage1.suspected_failures[Direction.REVERSE] = [Hop.new("218.101.61.52", ip_info)]
outage2.suspected_failures[Direction.FORWARD] = [Hop.new("218.101.61.52", ip_info)]

merged_outage = MergedOutage.new([outage1, outage2])

#p.execute_poison("wisc.bgpmux", "1424")
p.check_poisonability(merged_outage, true)
