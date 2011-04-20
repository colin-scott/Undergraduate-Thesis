#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'mail'
require 'base64'

#Emailer.deliver_outage_detected("1.2.3.4", ["mlab2.par01.measurement-lab.org [8 minutes]", "mlab2.lga01.measurement-lab.org [8 minutes]"],
#                                ["mlab2.nuq01.measurement-lab.org [(n/a)]", "node1.planetlab.albany.edu [2010-12-27 14:09:25 -0800]"],
#                               ["mlab2.nuq01.measurement-lab.org [(n/a)]", "node1.planetlab.albany.edu [2010-12-27 14:09:25 -0800]"],
#                               ["mlab2.nuq01.measurement-lab.org [(n/a)]", "node1.planetlab.albany.edu [2010-12-27 14:09:25 -0800]"],
#                               ["mlab2.nuq01.measurement-lab.org [(n/a)]", "node1.planetlab.albany.edu [2010-12-27 14:09:25 -0800]"])
#Emailer.deliver_isolation_results("mlab2.par01.measurement-lab.org", "1.2.3.4", "dataset", "reverse", ["mlab.emaxla.edu", "asfe.eee.ddd.ccc"] * 5, ["asfe.eee.ddd.ccc"] * 10, true, ["5.4.3.2", "6.5.4.3"] * 5, [], [], [], [], [], [], "" , false)
#puts Base64::encode64(File.read("../data/dots/planetlab-node3.it-sudparis.eu132.252.152.193_20112141651.jpg"))
Emailer.deliver_dot_graph("../data/dots/planetlab-node3.it-sudparis.eu132.252.152.193_20112141651.jpg")

#Emailer.deliver_test("./test.jpg")
#

$stderr.puts "sent..."
sleep
