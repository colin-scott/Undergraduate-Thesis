#!/homes/network/revtr/ruby-upgrade/bin/ruby

require 'isolation_module'
require '../spooftr_config.rb'
require 'yaml'

controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)

i = 0

loop do
    vps = controller.hosts.clone

    if !vps.empty?
        i = (i + 1) % vps.size
        curr_vp = vps[i]
        
        #                                                       Terrrrrrible
        target2receiver2succesfulsenders = registrar.receive_all_spoofed_pings(curr_vp, FailureIsolation.CloudfrontTargets, true) 

        # results is [[probes, receiver], [probes, receiver], ..] 
        t = Time.new
        File.open "../n2_pings/#{t.year}.#{t.month}.#{t.day}.#{t.hour}.#{t.min}_#{curr_vp}.txt", "w+" do |f|
            YAML.dump(target2receiver2succesfulsenders, f)
        end
    end

    $stderr.print "."

    sleep 280
end
