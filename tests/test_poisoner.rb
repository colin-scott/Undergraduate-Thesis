#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'isolation_module'
require 'drb'
require 'failure_dispatcher'
require 'outage'
require 'poisoner'
require 'outage_correlation'

require 'utilities'
Thread.abort_on_exception = true

p = Poisoner.new
outage1 = Marshal.load(IO.read("mlab1.ath01.measurement-lab.org_193.138.215.1_20110921081833.bin"))
outage2 = Marshal.load(IO.read("mlab1.ath01.measurement-lab.org_193.200.159.1_20110921081829.bin"))

outage1.src = "prin.bgpmux"
outage2.src = "PRIN.BGPMUX"

outage1.direction = Direction.REVERSE
outage2.direction = Direction.BOTH

outage1.suspected_failures[Direction.REVERSE] = ["145.1.2.1"]
outage1.suspected_failures[Direction.FORWARD] = [Hop.new()]

merged_outage = MergedOutage.new([outage1, outage2])


p.check_poisonability(m)
