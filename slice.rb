#!/homes/network/revtr/ruby/bin/ruby

# should be included, not executed!

require 'drb'
require '../spooftr_config'

class Slice
       
    attr_accessor :slice
    
    def initialize(slice)
        @slice = slice
    end 
    
    def command(command, vps, timeout=30)
        
        # Name the file based on the process ID, to avoid conflicts
        file = "/tmp/#{$$}.pptasks"
        
        begin
            
            # I need my variables! 
            if ($PPTASKS == nil || (!vps.is_a?(Array) && vps != false)) then
                raise ArgumentError, "One or more provided arguments is invalid."
            end

            # Empty?
            return Array.new if (vps != false && vps.length == 0)
            
            # Seriously... I'm not even joking...
            command.gsub!("\"","\\\\\\\\\\\"")
            command.gsub!("`","\\\\\\\\\\\\\`")
            command.gsub!("'","\\\\\\\\\\\\\'")
        
            # Create a temporary file
            File.open(file, 'w') { |f| f.write(vps.join("\n")) } 
            
            # Do the pptasks
            lines = `#{$PPTASKS} ssh #{@slice} #{file} 100 #{timeout} "#{command}" `.split("\n")
            
            # Parse output
            if lines == nil then return Array.new
            else lines end
    
        ensure
            
            # Make sure the file goes away
            File.delete(file) if File.exists?(file)

        end
        
    end
    
    # Return a hash pointing each vp to a boolean value (true if any output
    # returned by command)
    def if_output(command, vps=false, timeout=30)
        vps = get_all_vps if vps == false
        full_command = "if [ `#{command} | wc -l` -ne 0 ]; then hostname --fqdn; fi;"
        hostname_parse(vps, self.command(full_command, vps, timeout))
    end
    
    # Returns a hash pointing all VPs who return their hostname on the given command 
    def if_outputs_hostname(command, vps)
        hostname_parse(vps, self.command(command, vps, 240))
    end

    # Returns a hash pointing all VPs who are returning their hostname
    def hostname_check(vps)
        self.if_outputs_hostname("hostname --fqdn", vps)
    end
    
    # Same as the above, but tries to issue the command using our scripts 
    def controller_check(vps)
        begin
            #vps.map! do |vp| 
            #    (vp.include?("mlab")) ? $pl_host2ip[vp] : vp
            #end

			controllable = ProbeController::issue_to_controller { |controller|
			    controller.check_up_hosts(vps, {:backtrace => caller})
			}
            #DRb.start_service
            #controllable = DRbObject.new(nil, File.new(File::expand_path($CONTROLLER_INFO)).gets).check_up_hosts(vps, {:backtrace => caller})
            return hostname_parse(vps, controllable)
        ensure
            DRb.stop_service
        end
    end

    # Restart code
    def restart(vps)
        self.command('killall vantage_point.rb; sleep 5; killall -9 vantage_point.rb; cd ~/ethan/reversepaths/measurements/revtr/; echo "./vantage_point.rb 1>> /tmp/vp_log.txt 2>&1" | at now', vps)
    end

    def restart_and_check(vps)
        self.restart(vps)
        sleep 60
        self.controller_check(vps)
    end

    private

    @bad_hostnames
     
    def get_bad_hostnames
        require 'sql'
        @bad_hostnames = BadHostname.all
    end

    def get_all_vps
        require 'sql'
        VantagePoint.all(:conditions => {:active => true}).collect { |vp| vp.vantage_point }
    end 
    
    # Parse lines into a nice hash to return
    def hostname_parse(vps, hostnames)
       get_bad_hostnames if @bad_hostnames == nil
       hash = Hash.new
       vps.each { |vp| hash[vp] = false }
       hostnames.each { |vp| 
           # Make sure that we aren't getting a wrong alias for the hostname
           bhn = @bad_hostnames.find { |entry| entry.hostname == vp }
           if bhn != nil then hash[bhn.vantage_point.vantage_point] = true
           else hash[vp] = true end
       }
       hash
    end
end
