#!/homes/network/revtr/ruby/bin/ruby

require 'mail'

Emailer.deliver_outage_detected("1.2.3.4", ["mlab2.par01.measurement-lab.org [8 minutes]", "mlab2.lga01.measurement-lab.org [8 minutes]"],
                                ["mlab2.nuq01.measurement-lab.org [(n/a)]", "node1.planetlab.albany.edu [2010-12-27 14:09:25 -0800]"],
                               ["mlab2.nuq01.measurement-lab.org [(n/a)]", "node1.planetlab.albany.edu [2010-12-27 14:09:25 -0800]"],
                               ["mlab2.nuq01.measurement-lab.org [(n/a)]", "node1.planetlab.albany.edu [2010-12-27 14:09:25 -0800]"],
                               ["mlab2.nuq01.measurement-lab.org [(n/a)]", "node1.planetlab.albany.edu [2010-12-27 14:09:25 -0800]"])
#Emailer.deliver_isolation_results("mlab2.par01.measurement-lab.org", "1.2.3.4", "reverse", ["mlab.emaxla.edu", "asfe.eee.ddd.ccc"] * 5, ["asfe.eee.ddd.ccc"] * 10, ["5.4.3.2", "6.5.4.3"] * 5)
#Emailer.deliver_isolation_exception(Exception.new "Yo mamma")
