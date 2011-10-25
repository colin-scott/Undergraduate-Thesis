#!/homes/network/revtr/ruby/bin/ruby

#$: << "."
#$stderr.puts $:.inspect
require_relative 'utilities'

#  Is controller_log used?
#  it does update controller on all VPs in the main thread, but now that will
#  happen before all the register threads are done.  have it do it at the end
#  of register instead (as an option)?
# registrar takes URI, is that good vs VP?  with VP, didn't immediately work
# to call back to get URI
# put a log message after the last waiting
# don't allow restarts in middle of measurements
$ID = "$Id: controller.rb,v 1.100 2010/08/21 01:56:48 ethan Exp $"
$VERSION = $ID.split(" ").at(2).to_f

require 'drb'
require 'drb/acl'
require 'timeout'
require 'optparse'
require 'socket'
require 'set'
require 'resolv'

# we use OpenDNS (anycasted) for test pings
$TEST_IP = "8.8.8.8"

#$split_hash = Hash.new(0)
#
#class String
#    alias :old_split :split
#    def split(pattern=$;,limit=0)
#        $split_hash[caller[0]] += 1
#        old_split(pattern,limit)
#    end
#end

class SockTimeout < Timeout::Error
    def initialize(extended_msg="timed out")
        @extended_msg=extended_msg
    end
    def to_s
        super + ":#{@extended_msg}"
    end
end

# when we need to raise an error about something that happened at a VP
class VPError < RuntimeError
    attr :hostname
    def initialize(hostname,msg=nil)
        @hostname = hostname
        super(msg)
    end
    def to_s
        super + ":" + hostname
    end
end

class ReceiverError < VPError; end
class UnknownVPError < VPError; end
class SpooferError < VPError; end

class EmptyPingError < VPError ; end
class BadPingError < VPError 
    # although this says ping, the ping method actually returns an array, so
    # this will be an array
    def initialize(hostname,ping,msg=nil)
        @ping=ping
        super(hostname,msg)
    end
    def to_s

        super + "\n" + @ping.join("\n")
    end
end

class QuarantineFailure < VPError
    def initialize(hostname,original_exception,quarantine_exception)

        @original_exception=original_exception
        @quarantine_exception=quarantine_exception
        super(hostname)
    end

    attr_reader :hostname, :original_exception, :quarantine_exception

    def to_s

        super + "[#{@original_exception},#{@quarantine_exception}]"
    end
end

class Registrar
    def initialize(controller)
        @controller=controller
    end

    # raises the exception that 
    # note that this is different behavior than controller.register, which
    # just returns the exception
    def register(vp)
        @controller.log("Register attempt: #{vp.uri}")

        name = nil
        begin
            name = vp.name
        rescue
        end

        uri=vp.uri
        # could add in next line for backwards compatability
        # uri= (vp.is_a?(String) ? vp : vp.uri)
        result=@controller.register(uri, name)
        if not result.nil?
            raise result
        end

        result
    end

    # unregisters this VP at this URI only
    def unregister(vp)
        name = nil
        begin
            name = vp.name
        rescue
        end

        uri=vp.uri
        # could add in next line for backwards compatability
        # uri= (vp.is_a?(String) ? vp : vp.uri)
        name ||= Controller::uri2hostname(uri)
        @controller.unregister_host(name,uri)
    end

    def garbage_collect()
        GC.start
    end

    # vp can either be a string or a Prober object (via DRb)
     def client_reverse_traceroute(vp,dsts,backoff_endhost=true)
        @controller.log("Trying to measure reverse traceroute from #{dsts.join(",")} back to #{vp}")    
        pings=[]
        uri= (vp.is_a?(String) ? vp : vp.uri)
        #         begin
        #             Timeout::timeout(30, SockTimeout.new("#{uri} timed out after 30 seconds on a test ping to #{$TEST_IP}.  Aborting reverse traceroute.")){
        #                 pings=vp.ping([$TEST_IP]).split("\n")
        #                 raise EmptyPingError.new(host, "Test ping to #{$TEST_IP} came back empty.  Aborting reverse traceroute.") if pings.nil? or pings.length==0
        #                 if (pings.length==1 and pings[0].split(" ")[0]==$TEST_IP)
        #                     @controller.log("Successful test ping for reverse traceroute from #{dsts.join(",")} back to #{vp}: #{pings}")
        #                 else
        #                     raise BadPingError.new(host,pings, "Test ping to #{$TEST_IP} failed.  Aborting reverse traceroute.")
        #                 end
        #             }
        #         rescue
        #             @controller.log("Unsuccessful test ping for reverse traceroute from #{dsts.join(",")} back to #{vp}: #{pings}.  FAILING!\n#{$!.class}: #{$!.to_s}")
        #             raise RuntimeError.new("#{$!.class}: #{$!.to_s}")
        #         end
        result=@controller.register_vp(vp,1)
         if not result.nil?
             raise result
         end
        host=vp.hostname
        @controller.log("Measuring reverse traceroute from #{dsts.join(",")} back to #{host}")    
        reached, failed, reached_trivial, dst_not_reachable =reverse_traceroute(dsts.collect{|dst| [host,dst]},"/tmp",backoff_endhost)
 
        results={}
        all_reached=[]
        pings= get_pings( reached + reached_trivial )
        (reached + reached_trivial).each{|rtr|
            results[[rtr.src,rtr.dst]] = rtr.get_revtr_string(pings)
        }
        failed.each{|rtr|
            results[[rtr.src,rtr.dst]] = "Unable to measure reverse path."
        }
        dst_not_reachable.each{|rtr|
            results[[rtr.src,rtr.dst]] = "Destination #{rtr.dst} unreachable with forward traceroute from #{rtr.src}, so no reverse traceroute attempted."
        }
 
         # unregister
         begin
             controller_uri=@controller.get_uri(host)
             if controller_uri==uri
                 @controller.unregister_host(host)
             end
         rescue
            @controller.log "Unable to unregister #{vp}: #{$!}"
         end
        return results
    end

    # default ttl range is (1..30)
    def client_spoofed_traceroute(source, dests, receivers=nil, already_registered=false)
        if receivers.nil?
            receivers = @controller.hosts.clone[0..5] # TODO: randomize the receivers
            # XXX 5 is a magic number
            #
        end

        pingspoof_interface(source, dests, receivers, already_registered) do |hostname, dests, receivers|
            SpoofedTR::sendProbes(hostname, dests, receivers, @controller)
        end
    end

    def batch_spoofed_traceroute(srcdst2stillconnected)
        SpoofedTR::sendBatchProbes(srcdst2stillconnected, @controller)
    end

    def receive_batched_spoofed_pings(srcdst2stillconnected)
        SpoofedPing::receiveBatchProbes(srcdst2stillconnected, @controller)
    end

    # sends out spoofed pings from all other nodes as this source 
    # This is only temporary so that we can play around with outages by hand before
    # we build the full blown system
    def receive_all_spoofed_pings(source, dests, already_registered=false)
        receive_spoofed_pings(source, dests, @controller.hosts.clone, already_registered)
    end

    # sends out spoofed pings from the given set of nodes as the source 
    def receive_spoofed_pings(source, dests, spoofers, already_registered=false)
        pingspoof_interface(source, dests, spoofers, already_registered) do |hostname, dests, spoofers|
            SpoofedPing::receiveProbes(hostname, dests, spoofers, @controller)
        end
    end

    def send_all_spoofed_pings(source, dests, already_registered=false)
        send_spoofed_pings(source, dests, @controller.hosts.clone, already_registered)
    end

    def send_spoofed_pings(source, dests, receivers, already_registered=false)
        pingspoof_interface(source, dests, receivers, already_registered) do |hostname, dests, receivers|
            SpoofedPing::sendProbes(hostname, dests, receivers, @controller)
        end
    end

    def ping(source, dests, already_registered=false)
        # reduuundanttt
        if !already_registered
           register_result = register(source) # may throw exception (back at the caller? --not sure how Drb handles this)
           # we want an exception to be thrown back at the client
        end

        results = Ping::sendProbes(source, dests, @controller)

        begin
           unregister(source) unless already_registered
        rescue
           @controller.log "Unable to unregister #{source}: #{$!}"
           return
        end

        results
    end

    # returns hash
    #   src -> [pingable dsts] # precondition: all srcs and dsts already registered
    def all_pairs_ping(srcs, dsts)
        return Ping::all_pairs_ping(srcs,dsts,@controller)
    end

    # TODO: automatically check if the VP is already registered
    def traceroute(source, dests, already_registered=false)
        # reduuundanttt
        if !already_registered
           register_result = register(source) # may throw exception (back at the caller? --not sure how Drb handles this)
           # we want an exception to be thrown back at the client
        end

        results = Traceroute::sendProbes(source, dests, @controller)

        begin
           unregister(source) unless already_registered
        rescue
           @controller.log "Unable to unregister #{source}: #{$!}"
           return
        end

        results
    end

    private

    def pingspoof_interface(source, dests, helper_vps, already_registered, &block)
        raise ArgumentError.new "Cannot distinguish more than 2047 paths at once" if dests.size > 2047
        hostname = source.is_a?(String) ? source : source.hostname
        helper_vps.delete(hostname) if helper_vps.is_a?(Array)

        if !already_registered
           register_result = register(source) # may throw exception (back at the caller? --not sure how Drb handles this)
           # we want an exception to be thrown back at the client
        end

        $pl_host2ip["toil.cs.washington.edu"] = "128.208.4.244" # XXX
        
        results = block.call(hostname, dests, helper_vps)

        begin
           unregister(source) unless already_registered
        rescue
           @controller.log "Unable to unregister #{source}: #{$!}"
           return
        end
         
        return results
    end
end

# issues:
# - probably not thread safe on deleting vps
# - need to be consistent between hostnames and vps, probably best thing to do
# is just hash on hostnames, then call .values when i want the vps
# - really should just start up receive, only kill after all receivers send
# - handle exceptions in spoof
# - will the RPC calls timeout on long probe requests?

class Controller
    def Controller::calculate_ping_timeout(numtargs)

        # figure 30 parallel threads, max time for 1 is 2 seconds
        (numtargs.to_f/30.0).ceil * 2 + 10
    end

    def Controller::calculate_spoof_timeout(numtargs)

        (numtargs.to_f/20.0).ceil * 2 + 10
    end

    def Controller::calculate_traceroute_timeout(numtargs)

        # figure 30 parallel threads, max time for 1 is 20 seconds
        (numtargs.to_f/30.0).ceil * 20 + 10  
    end

    # some VPs for some reason register w the wrong name.  this gives those
    # mappings
    $rename_vp={ "planetlab1.esl" => "planetlab1.cs.colorado.edu", "planetlab2.esl" => "planetlab2.cs.colorado.edu", "swsat1502.mpi-sws.mpg.de" => "planetlab03.mpi-sws.mpg.de", "swsat1500.mpi-sws.mpg.de" => "planetlab01.mpi-sws.mpg.de", "swsat1501.mpi-sws.mpg.de" => "planetlab02.mpi-sws.mpg.de", "swsat1505.mpi-sws.mpg.de" => "planetlab06.mpi-sws.mpg.de", "swsat1503.mpi-sws.mpg.de" => "planetlab04.mpi-sws.mpg.de", "planetslug7.soe.ucsc.edu" => "planetslug7.cse.ucsc.edu" }

    def Controller::rename_uri_and_host(uri,hostname=nil)
        if hostname.nil? and uri.nil?
            return [nil,nil]
        end
        if hostname.nil?
            hostname=Controller::uri2hostname(uri)
        end
        # mlab nodes can only be contacted back via their IP address for our
        # slice, not hostname.  so if we get an IP, we want to change the
        # "hostname" variable to be a hostname.  and if we got a hostname for
        # the URI, we want to sub in the IP address
        if $pl_ip2host[hostname].include?("measurement-lab.org")
            hostname=$pl_ip2host[hostname]
            if not $pl_host2ip.has_key?(hostname)
                raise RuntimeError, "Missing IP for M-Lab #{hostname} at #{uri}", caller
            end
            uri = uri.gsub(hostname, $pl_host2ip[hostname])
        elsif $rename_vp.has_key?(hostname)
            # note this line assigns both hostname and uri
            uri = uri.gsub(hostname, hostname=$rename_vp[hostname])
        end
        return [(uri.nil? ? nil : uri.downcase),hostname.downcase]
    end

    def set_max_alert_level(newlevel)
        @controller_log.set_max_alert_level(newlevel)
        @controller_log.puts "Changing alert level from " + @controller_log.max_alert.to_s + " to " + newlevel.to_s
    end

    # is this used, or is $LOG log used?
    def log(msg=nil, level=3)
        return @controller_log unless msg # hack -- allow clients to set log level, call log.debug, etc. 
        @controller_log.puts(msg, level)
    end

    # if test_controller is true, won't do things like dump VPs
    def initialize(test_controller,configfn,logger,vpfn=nil)
        @test=test_controller
        @configfn=configfn
        @controller_log = logger 
        
        acl=ACL.new(%w[deny all
                    allow *.cs.washington.edu
                    allow localhost
                    allow 127.0.0.1
                    ] )
        @drb=DRb.start_service nil, self, acl
        @vp_lock = Mutex.new
        @hostname2vp=Hash.new
        @hostname2uri=Hash.new
        @quarantine_lock = Mutex.new
        @under_quarantine = Hash.new(false)
        @resolver = Resolv::DNS.new
        ProbeController::set_server(:controller,self)
        @ulimit=`ulimit -n;`.chomp("\n").to_i
        if not vpfn.nil?
            log("loading VPs from #{vpfn}")
            File.open(vpfn, "r"){|f|
                f.each_line{|vp|
                    Thread.new(vp){|my_vp| self.register(*(my_vp.chomp("\n").split(" ")))}
                }
            }
        end
    end

    attr_reader :ulimit, :drb

    def version

        return $VERSION
    end

    def uri

        self.drb.uri
    end
    
    # if touch and prune, we try to issue a command on them and only retain
    # those that respond
    def hosts(touchAndPrune=false)

        hosts=@vp_lock.synchronize{@hostname2vp.keys}
        if touchAndPrune
            check_up_hosts(hosts)
        else
            hosts
        end
    end

    #hostlist should be a hash, but can go to nothing
    # or can go to VPs, say.
    # note: we are no longer explicitly pruning here, instead we are pruning inside
    # issue_command bc we are quarnatining in there
    # in other words, it always prunes now, but it may add back if
    # quarantining is successful
    def check_up_hosts(hostlisthash, settings={ :retry => true, :maxalert => NO_EMAIL, :timeout => 30})

        if hostlisthash.class==Array
            hostlisthash=hostlisthash.to_h(true)
        end
        if not settings.include?(:timeout)
            settings[:timeout]=30
        end
        if not settings.include?(:retry)
            settings[:retry]=true
        end
        if not settings.include?(:maxalert)
            settings[:maxalert]=NO_EMAIL
        end
        results, unsuccessful_hosts=issue_command_on_hosts(hostlisthash,settings){|h,p| h.backtic("hostname --fqdn").chomp("\n").strip.downcase}

        uphosts=[]
        results.each{|vp|
             uphosts <<  ($rename_vp.has_key?(vp.at(0)) ? $rename_vp[vp.at(0)] : vp.at(0))
            if vp.at(0) != vp.at(1)
                log "check_up_hosts(): vp.at(0) != vp.at(1):  #{vp.join(" ")}"
            end
        }
#         if prune
#             unsuccessful_hosts.each{|h|
#                 self.unregister_host(h)
#             }
#         end
       
        return uphosts
    end

    # locked is whether we care about locking the count
    def vp_count(locked=false)

        if locked
            return @vp_lock.synchronize{@hostname2vp.length}
        else 
            return @hostname2vp.length
        end
    end

    def has_host?(hostname)
        first_result = @vp_lock.synchronize{@hostname2vp.has_key?(hostname.downcase)}
        return true if first_result # uglyyyy
        @vp_lock.synchronize{@hostname2vp.has_key?(@resolver.getaddress(hostname).to_s)}
    end

    # raises UnknownVPError if can't find it
    def get_vp(hostname)
        if !hostname.respond_to?(:downcase)
            log("Given hostname doesn't respond to :downcase")
            raise UnknownVPError.new(hostname), "UNKNOWN VP #{hostname} in controller.get_vp", caller
        end

        vp=@vp_lock.synchronize{@hostname2vp[hostname.downcase]}

        if vp.nil?
            log("no matching vp for #{hostname}")
            raise UnknownVPError.new(hostname), "UNKNOWN VP #{hostname} in controller.get_vp", caller
        end
        return vp
    end

    def dump_vps(filename)

        vp_s=""
        @vp_lock.synchronize do
            @hostname2uri.each_pair{|host,uri|
                vp_s += "#{uri} #{host}\n"
            }
        end
        File.open(filename, "w"){|f|
            f.puts vp_s
#             @vp_lock.synchronize do
#                 @hostname2uri.each_pair{|host,uri|
#                     f.puts "#{uri} #{host}"
#                 }
#             end
        }
    end

    # raises UnknownVPError if can't find it
    def get_uri(hostname)
        uri=@vp_lock.synchronize{@hostname2uri[hostname.downcase]}

        if uri.nil?
            log("no matching vp for #{hostname}")
            raise UnknownVPError.new(hostname), "UNKNOWN VP #{hostname} in controller.get_vp", caller
        end
        return uri
    end

    # note that this will return the IP, not the hostname, if the given URI
    # has an IP instead of hostname
    def Controller::uri2hostname(uri)
        uri.chomp("\n").split("/").at(-1).split(":").at(0).downcase
    end

    def shutdown(code=7)
        begin
            log("Exiting controller: Received shutdown message #{code}")
            fn=""
            if (not vp_count==0) and (not @test)
                `mkdir -p #{$DATADIR}/vp_dumps`
                curr_date=Time.new.strftime("%Y.%m.%d.%H%M.%S")
                fn="#{$DATADIR}/vp_dumps/vp_dump.#{curr_date}"
                log "Dumping current VPs to #{fn}"
                self.dump_vps(fn)
            end
            if code==$UPGRADE_RESTART
                log "Restarting with #{@configfn} #{fn}"
                #Kernel::system("echo \"ulimit -n 100000; ulimit -n > timestamp/reverse_traceroute/data/ulimit_n.txt; sleep 5; ./controller.rb #{@configfn} #{fn} 1>> #{$stderr_FILE} 2>&1 \"|at now")
                is_test= (@test ? "-t":"")
                Kernel::system("echo \" ulimit -n 100000; ./controller.rb #{is_test} -c #{@configfn} -v #{fn} 1>> #{$stderr_FILE} 2>&1 \"| at now")
                sleep 5
            end
            # sleep to make sure at least one controller is up at all times, to
            # avoid triggering the cronjob
        rescue
            log "Exception shutting down #{$!.class} #{$!}"
        ensure
        # need to thread out, so that we return the DRb call before shutting
        # down
            Thread.new{
                self.drb.stop_service
                Kernel.exit(code)
            }
        end
    end

    def restart

        shutdown($UPGRADE_RESTART)
    end

    # since this gets called when we can't connect to the vp,
    # it must operate without requiring any calls to the vp
    # if uri is set, will only unregister if the registered uri matches
    def unregister_host(hostname,uri=nil)
        uri,hostname=Controller::rename_uri_and_host(uri,hostname)
        open_fds=lsof.length
        unregistered=false
        @vp_lock.synchronize do
            if uri.nil? or @hostname2uri[hostname]==uri
                @hostname2vp.delete(hostname)
                @hostname2uri.delete(hostname)
                unregistered=true
            end
        end
        if unregistered
            log("Unregistered #{hostname}: #{vp_count} total, #{open_fds} of #{self.ulimit} FDs")
        else
            log("Not unregistering #{hostname}: given URI #{uri} does not match stored one #{@hostname2uri[hostname]}")
        end
    end

    #seems like controller establishes a TCP connection w/ VP when it
    #regisers, again the first time you probe from it (different port), and
    #they end up in CLOSE_WAIT when the VP unregisters, but do not go away.
    #the one that does not go away is the one that was started when the VP
    #registered.  When it registers after restarting itself, the VP port in
    #lsof is not the same one i see in the controller log does not seem to be
    #a problem when you run vp with at-- they die appropriately

    # get list of open FDs
    # plus will also include . and ..
    def lsof
        Dir.new("/proc/#{Process.pid}/fd/").entries
    end

    # try to ping zooter
    # return nil if it works (isn't broken)
    # otherwise return the exception (does not raise it - returns it as the
    # return value)
    def vp_broken?(vp, test_ip=$TEST_IP)
        begin
            Timeout::timeout(30, SockTimeout.new("#{vp.uri} timed out after 30 on a test ping")){
                pings=vp.ping([test_ip]).split("\n")
                raise EmptyPingError.new(vp.uri) if pings.length==0
                if (pings.length==1 and pings[0].split(" ")[0]==test_ip)
                    return nil
                else
                    pings << "length: #{pings.length}"
                    pings << "#{test_ip}!=#{pings[0].split(" ")[0]}"
                    raise BadPingError.new(vp.uri,pings)
                end
            }
        rescue
            return $!
        end
    end

    def vp_at_uri_broken?(uri)
        begin
            vp=DRbObject.new nil, uri
            return vp_broken?(vp)
        rescue
            return $!
        end
    end

    # return nil if it registers successfully, otherwise returns the exception
    # right now, initialize calls this in serial for every VP, making it very
    # slow
    # need to parallelize
    # also need to make multithreaded access to the hashes safe
    def register(uri, name=nil)
        log("register attempt, inside controller. #{name}")
        open_fds=lsof.length
        begin
            uri,hostname=Controller::rename_uri_and_host(uri,hostname)
        rescue
            log("Unable to rename #{hostname} as #{uri}: #{$!}")
            return $!
        end

        name ||= hostname
        name = name.downcase

        if ( self.ulimit - open_fds < vp_count )
            log("Unable to register #{hostname} as #{uri}, too many open FDs: #{vp_count} total, #{open_fds} of #{self.ulimit} FDs", 1)
            return
        end

        wait=0
        retries=1
        
        if @vp_lock.synchronize{@hostname2uri.has_key?(name) and @hostname2uri[name]==uri}
            #**** should i retest here?****#
            return
        end
    
        except=true
        while retries>=0
            sleep(wait)
            retries += -1
            except=vp_at_uri_broken?(uri)
            if not except
                # register here
                new_vp=DRbObject.new nil, uri
                @vp_lock.synchronize do
                    @hostname2vp[name]=new_vp
                    @hostname2uri[name]=uri
                end
                log("Registered #{name} as #{uri}: #{vp_count} total, #{open_fds} of #{self.ulimit} FDs")
                return nil
            end
            log("Unsuccessful register #{name} as #{uri}, retrying: #{except}")
            wait= (wait==0)? 10 : wait*10
        end
        log("Unable to register #{name} as #{uri}: #{except}")
        return except
    end

    def register_vp(vp,retries,wait=0)
        open_fds=lsof.length
        if ( self.ulimit - open_fds < vp_count )
            log("Unable to register #{hostname} as #{uri}, too many open FDs: #{vp_count} total, #{open_fds} of #{self.ulimit} FDs", 1)
            return
        end
        hostname=vp.hostname
        uri=vp.uri
        except=true
        while retries>=0
            sleep(wait)
            retries += -1
            except=vp_broken?(vp)
            if not except
                # register here
                @vp_lock.synchronize do
                    @hostname2vp[hostname]=vp
                    @hostname2uri[hostname]=uri.downcase
                end
                log("Registered #{hostname} directly #{vp} at #{uri}: #{vp_count} total, #{open_fds} of #{self.ulimit} FDs")
                return nil
            end
            log("Unsuccessful register #{hostname} directly #{vp} at #{uri}, retrying: #{except}")
            wait= (wait==0)? 10 : wait*10
        end
        log("Unable to register #{hostname} directly #{vp} at #{uri}: #{except}")
        return except
    end

    # return the set of VPs (hostnames) currently under quarantine
    def under_quarantine
        @quarantine_lock.synchronize{@under_quarantine.keys}
    end
     
    # return nil if successful (at the moment, also returns nil if already
    # under quarantine by another thread, but could fix that with condition
    # variables, say)
    # otherwise return the exception
    # want other methods to be able to quarantine and move on
    # so this threads out and therefor the thread should be able to handle its
    # own exceptions
    def quarantine(hostname,maxalert,exception=nil)
        Thread.new(hostname,exception){|my_hostname,except|
            @quarantine_lock.synchronize do
                if @under_quarantine.include?(my_hostname)
                    log("Quarantine in effect for #{my_hostname} for #{except}")
                    return 
                end
                @under_quarantine[my_hostname] = true
            end
            log("Quarantining #{my_hostname} for #{except}:\n#{except.backtrace.join("\n")}")
            reg_return=nil
            begin
                uri=get_uri(my_hostname)
                unregister_host(my_hostname,uri)
    #        sleep(5)
    #
                reg_return=register(uri, my_hostname)
            # only exception this should see is  UnknownVPError
            rescue
                reg_return=$!
            end

            if reg_return
                qf=QuarantineFailure.new(my_hostname,except,reg_return)
                log(["Quarantining #{my_hostname} unsuccessful: #{except.class}", "EXCEPTION!  for #{my_hostname}:\n#{qf.to_s}\n#{qf.original_exception.backtrace.join("\n")}\n\nTest ping failure:\n#{qf.quarantine_exception.backtrace.join("\n")}"], [EMAIL,maxalert].max)
                return qf
            else
                log("Quarantining #{my_hostname} successful")
                @quarantine_lock.synchronize do
                    @under_quarantine.delete(my_hostname)
                end
                return nil
            end
        }
    end

    def probe_from_all(timeout=30, &probe_method)

        probe_from_all_w_opt_retry(timeout,false,&probe_method)
    end

    def probe_from_all_w_opt_retry (timeout, retry_command=false, &probe_method)

        results=[]
        threads = []
        unsuccessful_hosts=[]
        for host in self.hosts
            threads << Thread.new(host,retry_command) { |my_host,my_retry_command|
                begin
                    Thread.current[:success]=false # until proven true
                    Thread.current[:host] = my_host
                    my_vp=self.get_vp(my_host)
                    #probes,source=vp.ping(targets)
                    Timeout::timeout(timeout, SockTimeout.new("#{my_host} timed out after #{timeout} while probing from all")) {
                        probes=probe_method.call(my_vp)
                        Thread.current[:results]=probes
                        Thread.current[:success]=true
                    }
                rescue
                    if my_retry_command
                        my_retry_command=false
                        sleep 2
                        retry
                    else
                        quarantine(my_host,EMAIL,$!)
                    end
                end
            }
        end
        threads.each { |t|  
            log("waiting for #{t[:host]}")
            t.join 
            if t[:success]
                results << [t[:results],t[:host]]
            else
                unsuccessful_hosts << t[:host]
            end
        }
        return results, unsuccessful_hosts
    end

    # if no hosts given, upgrade all.  otherwise, given list of hostnames,
    # upgrade them
    def upgrade_vps(hosts=nil)

        log("Upgrading vps")
        if hosts
            if hosts.is_a?(Array)
                hosts=hosts.to_h(true)
            end
            issue_command_on_hosts(hosts,{ :retry => true, :maxalert => EMAIL, :timeout => 30}){|vp| vp.check_for_update}
        else
            probe_from_all_w_opt_retry(30,true){|vp| vp.check_for_update}
        end
    end

    def ping_from_all(targets,retry_failed=false)

        log("Pinging #{targets.length} from all.  Timeout=#{Controller::calculate_ping_timeout(targets.length)}")
        probe_from_all_w_opt_retry(Controller::calculate_ping_timeout(targets.length),retry_failed){|vp| vp.ping(targets)}
    end

    def traceroute_from_all(targets,retry_failed=false)

        log("Traceroute #{targets.length} from all.  Timeout=#{Controller::calculate_traceroute_timeout(targets.length)}")
        probe_from_all_w_opt_retry(Controller::calculate_traceroute_timeout(targets.length),retry_failed){|vp| vp.traceroute(targets)}
    end

    def ts_from_all(targets,retry_failed=false)

        log("Timestamp #{targets.length} from all.  Timeout=#{Controller::calculate_ping_timeout(targets.length)}")
        probe_from_all_w_opt_retry(Controller::calculate_ping_timeout(targets.length),retry_failed){|vp| vp.ts(targets)}
    end

    # given a hash from hostname to parameters (generally a list/array of
    # targets, but whatever the method takes), fan out over the hosts and
    # execute the method
    # valid settings include:
    # :retry
    # :maxalert
    # :timeout
    # :backtrace
    def issue_command_on_hosts(hostname2params,settings={ :retry => false, :maxalert => TEXT},&method)
        Thread.current[:name]="#{__method__}:#{hostname2params.inspect}"
        if settings.is_a?(Numeric)
            settings={ :timeout => settings }
        end
        timeout= ( settings.include?(:timeout) ? settings[:timeout] : 30 )
        retry_command = ( settings.include?(:retry) ? settings[:retry] : false )
        maxalert = ( settings.include?(:maxalert) ? settings[:maxalert] : TEXT )
        results=[]
        unsuccessful_hosts=[]
        threads = []
        hostname2params.each_pair{|hostname, params|
            threads << Thread.new(hostname,params,retry_command) { |my_hostname,my_params,my_retry_command|
                begin
                    Thread.current[:success]=false # until proven true
                    Thread.current[:host] = my_hostname
                    
                    # may raise UnknownVPError
                    my_vp=get_vp(my_hostname)
                    Timeout::timeout(timeout, SockTimeout.new("#{my_hostname} timed out after #{timeout} while issuing command")) {
                        method_return=method.call(my_vp,my_params)
                        Thread.current[:results]=method_return
                        Thread.current[:success]=true
                    }
                rescue
                    if my_retry_command
                        my_retry_command=false
                        sleep 2
                        retry
                    else
                        if settings.include?(:backtrace)
                            $!.set_backtrace($!.backtrace + settings[:backtrace])
                        end
                        quarantine(my_hostname,maxalert,$!)
                    end
                end
#                 rescue UnknownVPError
#                     # sleep and retry?  quarantine on its own won't do
#                     # anything, since it requires the URI
#                     log(["Unknown VP #{my_hostname}", "EXCEPTION! issue_command_on_hosts unknown host #{my_hostname}, " + $!.to_s], [$UNKNOWN_VP_ERROR,maxalert].max)
#                 rescue SockTimeout
#                     # quarantine since it already took a lot of time?
#                     log(["RPC Timeout at #{my_hostname}", "EXCEPTION! RPC to vp timeout " + $!.to_s], [$SOCK_TIMEOUT_ERROR,maxalert].max)
#                 rescue DRb::DRbConnError
#                     # retry most likely to work here?
#                     log(["#{my_hostname} refused connection", "EXCEPTION! #{my_hostname} refused connection: " + $!.to_s], [$DRB_CONNECT_ERROR,maxalert].max)
#                     self.unregister_host(my_hostname)
#                 rescue SystemCallError
#                     # retry probably unlikely to work here?
#                     log(["System call error at #{my_hostname}", "EXCEPTION VP SystemCallError::Error issue_command_on_hosts #{my_hostname} " +$!.to_s], [$VP_SYSCALL_ERROR,maxalert].max)
#                     log($!.backtrace.join("\n"))
#                 rescue Timeout::Error
#                     log(["Unexpected timeout from #{my_hostname}", "EXCEPTION Unexpected Timeout::Error issue_command_on_hosts " + $!.to_s], [$TIMEOUT_ERROR,maxalert].max)
#                     log($!.backtrace.join("\n"))
#                 rescue 
#                     log(["Unhandled exception from #{my_hostname}", "EXCEPTION! #{my_hostname} threw a probing error #{$!.class}: " + $!.to_s], [$GENERAL_ERROR,maxalert].max)
#                 end
        
            }
        }
        threads.each { |t|  
            log("waiting for #{t[:host]}")
            t.join
            if t[:success]
                 results << [t[:results],t[:host]]
            else
                unsuccessful_hosts << t[:host]
            end
        }
        return results, unsuccessful_hosts
    end

    def issue_command_on_hosts_w_maxalert(hostname2params,timeout,retry_command,maxalert=TEXT,&method)

        issue_command_on_hosts(hostname2params,{ :timeout => timeout, :retry => retry_command, :maxalert => maxalert}, &method)
    end

    def issue_command_on_hosts_w_opt_retry(hostname2params,timeout,retry_command=false,&method)

        issue_command_on_hosts(hostname2params,{ :timeout => timeout, :retry => retry_command, :maxalert => TEXT}, &method)
    end

    # returns [results, unsuccesful_hosts, privates, blacklisted]
    def ping(hostname2targets,settings={ :timeout => 180, :retry => false, :maxalert => TEXT})
        privates=[]
        blacklisted=[]
        hostname2targets.each{|host,targets|
            hostname2targets[host],privates,blacklisted=inspect_targets(targets,privates,blacklisted)
        }
        max_length=hostname2targets.values.collect{|x| x.length}.max
        if not settings.include?(:timeout)
            settings[:timeout]=Controller::calculate_ping_timeout(max_length)
        end
        log("Ping up to #{max_length}.  Timeout=#{settings[:timeout]}")
        return issue_command_on_hosts(hostname2targets,settings){|vp,targets| vp.ping(targets)} << privates << blacklisted
    end

    # returns [results, unsuccesful_hosts, privates, blacklisted]
    def traceroute(hostname2targets,settings={ :timeout => 180, :retry => false, :maxalert => TEXT})

        privates=[]
        blacklisted=[]
        hostname2targets.each{|host,targets|
            hostname2targets[host],privates,blacklisted=inspect_targets(targets,privates,blacklisted)
        }
        hostname2targets.delete_if {|host,targets| targets.length == 0 }
        max_length=hostname2targets.values.collect{|x| x.length}.max
        if not settings.include?(:timeout)
            settings[:timeout]=Controller::calculate_traceroute_timeout(max_length)
        end
        log("Traceroute up to #{max_length}.  Timeout=#{settings[:timeout]}")
        return issue_command_on_hosts(hostname2targets,settings){|vp,targets| vp.traceroute(targets)} << privates << blacklisted
    end

    # returns [results, unsuccesful_hosts, privates, blacklisted]
    def rr(hostname2targets,settings={ :retry => false, :maxalert => TEXT})

        privates=[]
        blacklisted=[]
        hostname2targets.each{|host,targets|
            hostname2targets[host],privates,blacklisted=inspect_targets(targets,privates,blacklisted)
        }
        hostname2targets.delete_if {|host,targets| targets.length == 0 }
        max_length=hostname2targets.values.collect{|x| x.length}.max
        if not settings.include?(:timeout)
            settings[:timeout]=Controller::calculate_ping_timeout(max_length)
        end
        log("RecordRoute up to #{max_length}.  Timeout=#{settings[:timeout]}")
        return issue_command_on_hosts(hostname2targets,settings){|vp,targets| vp.rr(targets)} << privates << blacklisted
    end

    # returns [results, unsuccesful_hosts, privates, blacklisted]
    def ts(hostname2targets,settings={ :retry => false, :maxalert => TEXT})

        privates=[]
        blacklisted=[]
        hostname2targets.each{|host,targets|
            hostname2targets[host],privates,blacklisted=inspect_targets(targets,privates,blacklisted)
        }
        hostname2targets.delete_if {|host,targets| targets.length == 0 }
        max_length=hostname2targets.values.collect{|x| x.length}.max
        if not settings.include?(:timeout)
            settings[:timeout]=Controller::calculate_ping_timeout(max_length)
        end
        log("Timestamp up to #{max_length}.  Timeout=#{settings[:timeout]}")
        return issue_command_on_hosts(hostname2targets,settings){|vp,targets| vp.ts(targets)} << privates << blacklisted
    end

    $MAX_HOLES=100
    # hash[receiver] -> hash[spoofer] -> targets
    # receivers and spoofers are hostnames for now
    # set timeouts
    # when to unregister VPs?
    # catch more general exceptions?
    # tie kill_and_retrieve to number of probes, but only in terms of how long it
    # takes to copy back
    # fail revtr on unsuccessful hosts?
    # Rescue Timeout::Error everywhere we call RPC/ 3rd party ?
    # option to specify a max number of parallel receivers
    # maxalert and retry may not be supported yet
    def spoof_rr(receiver2spoofer2targets, settings={ :retry => true, :parallel_receivers => :all})

        # this is for backwards compatability
        if settings.is_a?(Numeric) or settings.is_a?(Symbol)
            settings={ :parallel_receivers => settings }
        end
        settings[ :probe_type ] = :rr
        if (not settings.include?(:parallel_receivers)) or settings[:parallel_receivers]==:all
            spoof_and_receive_probes(receiver2spoofer2targets, settings){|x| x} 
        else 
            results=[]
            unsuccessful_receivers=[]
            privates=[]
            blacklisted=[]
            receivers=receiver2spoofer2targets.keys.clone.sort_by{rand}
            while not receivers.empty?
                curr_receivers=receivers[0...settings[:parallel_receivers]]
                receivers[0...settings[:parallel_receivers]]=[]
                h=Hash.new
                curr_receivers.each{|r|
                    h[r]=receiver2spoofer2targets[r]
                }
                log("Receivers are #{curr_receivers.join(" ")}")
                res,uns, pri,bla=spoof_and_receive_probes(h, settings){|x| x}
                results += res
                unsuccessful_receivers += uns
                privates += pri
                blacklisted += bla
            end
            return results,unsuccessful_receivers,privates,blacklisted
        end
    end

    def spoof_ts(receiver2spoofer2targets, settings={ :retry => true } )

        settings[ :probe_type ] = :ts
        spoof_and_receive_probes(receiver2spoofer2targets, settings) {|x| x.collect{|y| y.at(0)}} 
    end

    def spoof_tr(receiver2spoofer2targets, settings={ :retry => true } )

        settings[ :probe_type ] = :tr
        spoof_and_receive_probes(receiver2spoofer2targets, settings) {|x| x.collect{|y| y[0]}} 
    end
      
    # how many holes to punch for traceroute, and how to count the number of
    # probes/ decide how many to take?
    # timeout for traceroute spoofing probes
    # fetch timeout for traceroute
    #
    # because of the timing issues of hole punching, we can't really retry a
    # spoofer measurement, so retry_command is for the receiver onlyc
    # not positive if retry is always safe with our tools?
    def spoof_and_receive_probes(receiver2spoofer2targets, settings={ :probe_type => :rr, :retry => false }, &probe_requests_to_destinations )
        # thread out on receivers
        # iterate through until the next one will add too many targets
        # each time, add the targets to the receiver targets
        # and append to a receiver hash its targets
        # once i hit the limit, call receive, then thread out over the spoofers
        settings[ :probe_type ]=:rr if not settings.include?( :probe_type )
        settings[ :retry ]=false if not settings.include?( :retry )
        trivial_timeout=15
        results=[]
        unsuccessful_receivers=[]
        receiver_threads=[]
        privates=[]
        blacklisted=[]
        receiver2spoofer2targets.values.each {|spoofer2targets|
            spoofer2targets.each{|spoofer,targets|
                spoofer2targets[spoofer],privates,blacklisted=inspect_targets(targets,privates,blacklisted)
            }
            spoofer2targets.delete_if {|spoofer,targets| targets.empty?}
        }
        log "spoof_and_receive_probes(), receiver2spoofer2targets: #{receiver2spoofer2targets.inspect}"
        for receiver in receiver2spoofer2targets.keys
            log("receiver is " + receiver + " total targs " + receiver2spoofer2targets[receiver].values.collect{|requests| probe_requests_to_destinations.call(requests)}.flatten.length.to_s + " total spoofers " + receiver2spoofer2targets[receiver].length.to_s)
            receiver_threads << Thread.new(receiver,settings[:retry]) { |my_receiver_name,my_retry_command|
                begin # exception block for the receiver thread
                    total_targets=receiver2spoofer2targets[my_receiver_name].values.collect{|requests| probe_requests_to_destinations.call(requests)}.flatten.length.to_s
                    Thread.current[:receiver]=my_receiver_name
                    Thread.current[:success]=false # false until proven true
        
                    # may throw UnknownVPError
                    my_receiver=self.get_vp(my_receiver_name)
                    fid=0
                    Timeout::timeout(trivial_timeout, SockTimeout.new("#{my_receiver_name} timed out after #{trivial_timeout} getting ready to receive spoofed #{settings[:probe_type].to_s}")) {
                        fid=case settings[:probe_type]
                            when :rr
                                my_receiver.receive_spoofed_rr
                            when :ts
                                my_receiver.receive_spoofed_ts
                            when :tr
                                my_receiver.receive_spoofed_tr
                            end
                    }
# while i theoretically could catch the timeout here and assume that it might
# still be receiving, in practice i'll need the fid to fetch the file later
# could modify that if it ends up being a problem
                    
                    holes_to_punch=[]
                    probes_to_send=Hash.new { |hash, key| hash[key] = [] } 
                    spoofer_count=0
                    log("Before each_pair: #{my_receiver_name} #{receiver2spoofer2targets.inspect}")
                    receiver2spoofer2targets[my_receiver_name].each_pair{|spoofer,targets|
                        log("Before while loop: #{my_receiver_name} spoofer #{spoofer} targets #{targets.inspect}")
                        spoofer_count += 1
                        while targets.length>0
                            log("top of targets.length loop: spoofer for #{my_receiver_name} is " + spoofer + " #{targets.length} " + probe_requests_to_destinations.call(targets).join(","))
                            if (holes_to_punch.length + targets.length >= $MAX_HOLES) or (spoofer_count==receiver2spoofer2targets[my_receiver_name].keys.length)
                                num_to_take=[$MAX_HOLES-holes_to_punch.length,targets.length].min
                                init_length=holes_to_punch.length
                                probes_to_send[spoofer] += targets[0...num_to_take]
                                holes_to_punch += probe_requests_to_destinations.call(targets[0...num_to_take])
                                targets[0...num_to_take]=[]
                                log("before send probes: spoofer for #{my_receiver_name} is " + spoofer + " down to #{targets.length} " )
                                # send probes
                                log(my_receiver_name + " punching holes " + holes_to_punch.join(" "))
                                begin 
                                    receiver_timeout=Controller::calculate_ping_timeout(holes_to_punch.length)
                                    Timeout::timeout(receiver_timeout, SockTimeout.new("#{my_receiver_name} timed out after #{receiver_timeout} punching #{holes_to_punch.length} holes")) {
                                        my_receiver.punch_holes(holes_to_punch)
                                    }
                                # handle timeouts a bit differently bc it
                                # still might have punched some holes
                                # so we continue even if it fails the 2nd time
                                rescue SockTimeout
                                    if my_retry_command
                                        my_retry_command=false
                                        sleep 2
                                        retry
                                    else
                                        log(["#{my_receiver_name} timed out punching holes", "EXCEPTION! " + $!.to_s], $SOCK_TIMEOUT_ERROR)
                                    end
                                rescue
                                    if my_retry_command
                                        my_retry_command=false
                                        sleep 2
                                        retry
                                    else
                                        # we raise here to get to the
                                        # quarantine
                                        # no point in spoofing
                                        raise
                                    end
                                end #  send probes
                                sleep 2
                                spoofer_threads=[]
                                max_length=probes_to_send.values.collect{|x| x.length}.max
                                spoofer_timeout=Controller::calculate_spoof_timeout(max_length)
                                for spoofer_key in probes_to_send.keys
                                    spoofer_threads << Thread.new(spoofer_key){|my_spoofer_name|
                                        begin # exception block for spoofer thread 
                                            Thread.current[:host] = my_spoofer_name

                                            # may raise UnknownVPError
                                            my_spoofer=self.get_vp(my_spoofer_name)
                                            log("spoofing as #{my_receiver_name} from #{my_spoofer_name}: #{probes_to_send[my_spoofer_name].length} #{probe_requests_to_destinations.call(probes_to_send[my_spoofer_name]).join(" ")}")
                                                    
                                            Timeout::timeout(spoofer_timeout, SockTimeout.new("#{my_spoofer_name} timed out after #{spoofer_timeout} spoofing #{probes_to_send[my_spoofer_name].length} probes as #{my_receiver_name}")){
                                                case settings[:probe_type]
                                                when :rr
                                                    my_spoofer.spoof_rr({$pl_host2ip[my_receiver_name] => probes_to_send[my_spoofer_name]})
                                                when :ts
                                                    my_spoofer.spoof_ts({$pl_host2ip[my_receiver_name] => probes_to_send[my_spoofer_name]})
                                                when :tr
                                                    my_spoofer.spoof_tr({$pl_host2ip[my_receiver_name] => probes_to_send[my_spoofer_name]}) 
                                                end
                                            }
                                        rescue
                                            if settings.include?(:backtrace)
                                                $!.set_backtrace($!.backtrace + settings[:backtrace])
                                            end
                                            log "Spoofer error"
                                            quarantine(my_spoofer_name,( settings.include?(:maxalert) ? settings[:maxalert] : TEXT ),$!)
                                         end # exception block for spoofer thread 
                                    }
                                end # for spoofer_key in probes_to_send.keys
# need to make sure the other threads all end (w timeouts if nothing else) to
# make sure join returns
                                spoofer_threads.each{|t|
                                    log("Waiting for spoofer #{t[:host]}")
                                    t.join
                                }
                                log("bottom of targets.length loop: spoofer for #{my_receiver_name} was " + spoofer + " down to #{targets.length} " )
                                holes_to_punch=[]
                                probes_to_send.clear
                            else # ^--  if $MAX_HOLES_TO_PUNCH or spoofer_count == # spoofers
                                holes_to_punch += probe_requests_to_destinations.call(targets)
                                probes_to_send[spoofer] += targets
                                targets=[]
                            end
                        end # while targets.size>0
                    } # receiver2spoofer2targets[my_receiver_name].each_pair{|spoofer,targets|

                    
                    # sleep to make sure last probes get back
                    sleep 2
                    fetch_timeout= 20 + (total_targets.to_f/100.0).round
                    Timeout::timeout(fetch_timeout, SockTimeout.new("#{my_receiver_name} timed out after #{fetch_timeout} trying to kill and retrieve #{fid}")) {
                        probes=my_receiver.kill_and_retrieve(fid)
                        log("Saving results for " + my_receiver_name)
                        Thread.current[:results]=probes
                        Thread.current[:success]=true
                    }
                rescue  # end exception block for the receiver thread
                    if my_retry_command
                        my_retry_command=false
                        sleep 2
                        retry
                    else
                        if settings.include?(:backtrace)
                            $!.set_backtrace($!.backtrace + settings[:backtrace])
                        end
                        quarantine(my_receiver_name,( settings.include?(:maxalert) ? settings[:maxalert] : TEXT ),$!)
                    end
                end # exception block for receiver thread
            } # receiver_threads << Thread.new
        end # for receiver in 
        receiver_threads.each{|rt|
            log("Waiting for receiver #{rt[:receiver]}")
# need to make sure the other threads all end (w timeouts if nothing else) to
# make sure join returns
            rt.join
            if rt[:success]
                log("Adding results for #{rt[:receiver]}")
                results << [rt[:results],rt[:receiver]]
            else
                unsuccessful_receivers << rt[:receiver]
            end
        }
        return results,unsuccessful_receivers,privates,blacklisted
    end

### WILL NEED TO KILL MORE THAN ONE PROCESS FOR SINGLE IP?
    def get_results(in_progress)

        hostname2pid = {}
        in_progress.each { |pid, hostname|
            hostname2pid[hostname] = pid
        }     
        issue_command_on_hosts(hostname2pid, 30){ |vp, pid| vp.get_results(pid) }
    end

    def execute_ping(hostname2targets)

        issue_command_on_hosts(hostname2targets, 30) { |vp, dests| vp.launch_ping(dests) }
    end

    def execute_rr(hostname2targets)

        issue_command_on_hosts(hostname2targets, 30) { |vp, dests| vp.launch_rr(dests) }
    end

    def execute_traceroute(hostname2targets)

        issue_command_on_hosts(hostname2targets, 30) { |vp, dests| vp.launch_traceroute(dests) }
    end

    def execute_ts(hostname2targets)

        issue_command_on_hosts(hostname2targets, 30) { |vp, dests| vp.launch_ts(dests) }
    end
end



# This hash will hold all of the options
# parsed from the command-line by
# OptionParser.
options = Hash.new

optparse = OptionParser.new do |opts|
    options[:config] = "/homes/network/ethan/timestamp/reverse_traceroute/reverse_traceroute/config_zooter.rb"
    opts.on( '-c', '--config FILE', "config FILE (default=/homes/network/ethan/timestamp/reverse_traceroute/reverse_traceroute/config_zooter.rb)" ) do|f|
          options[:config] = f
    end
    opts.on( '-h', '--help', 'Display this screen' ) do
        puts opts
        exit
    end
    options[:kill] = false
    opts.on( '-k', '--[no-]kill', "Kill other instances of controller.rb (default=false)" ) do|n|
          options[:kill] = n
    end
    options[:test] = false
    opts.on( '-t', '--[no-]test', "Whether this is a test and should NOT be considered the live controller (default=false)" ) do|n|
          options[:test] = n
    end
    options[:vp_uri_list] = nil
    opts.on( '-v', '--vps [FILE]', "VP uri list [FILE] (default=nil)" ) do|f|
        $LOG.puts "setting vp uri list to #{f}"
        options[:vp_uri_list] = f
    end
    options[:log_level] = Logger::DEBUG
    opts.on( '-l', '--log-level [LEVEL]', "The log level to use (e.g. Logger::INFO, Logger::DEBUG)") do|l|
        # This doesn't work....
        options[:log_level] = l
    end
    options[:actual_test] = false
    opts.on( '-a', '--[no-]test-real', "Whether this is a test and should NOT be considered the live controller (default=false)" ) do
          options[:actual_test] = true
          options[:log_level] = Logger::ERROR
    end
end

# Parse the command-line. Remember there are two forms
# # of the parse method. The 'parse' method simply parses
# # ARGV, while the 'parse!' method parses ARGV and removes
# # any options found there, as well as any parameters for
# # the options. 
optparse.parse!

require options[:config]

require_relative 'file_lock'
Lock::acquire_lock("controller_lock.txt") unless options[:actual_test]

require "#{$REV_TR_TOOL_DIR}/reverse_traceroute"
require "#{$REV_TR_TOOL_DIR}/spoofed_traceroute"
require "#{$REV_TR_TOOL_DIR}/traceroute"
require "#{$REV_TR_TOOL_DIR}/spoofed_ping"
require "#{$REV_TR_TOOL_DIR}/ping"
`mkdir /tmp/revtr`
$stderr_FILE="/tmp/revtr/controller.out"

if options[:kill] 
    my_pid= Process.pid
    pids= `ps ux | awk '/controller.rb/ && !/awk/ {print $2}'`.split("\n").collect{|x| x.to_i}
    pids.each{|pid|
        if not pid==my_pid
            Process.kill("SIGTERM",pid)
            $LOG.puts "Killing old process #{pid}"
        end
    }
    sleep 5
    pids= `ps ux | awk '/controller.rb/ && !/awk/ {print $2}'`.split("\n").collect{|x| x.to_i}
    pids.each{|pid|
        if not pid==my_pid
            Process.kill("SIGKILL",pid)
        end
    }
end

if options[:actual_test]
    controller_log = LoggerLog.new($stderr)
    controller_log.debug("the controller log is working")
else

    controller_log = LoggerLog.new('/homes/network/revtr/revtr_logs/isolation_logs/controller.log')
end

controller_log.level = options[:log_level]

c=Controller.new(options[:test],options[:config],controller_log,options[:vp_uri_list])

# # We need the uri of the service to connect a client
puts "controller uri: #{c.uri}"
c.log "Version number #{$VERSION}"
c.log("Controller started at #{c.uri}")
uri_port=c.uri.chomp("\n").split("/").at(-1).split(":").at(1)
my_ip= UDPSocket.open {|s| s.connect($TEST_IP, 1); s.addr.last }
# can also do 
#my_ip=`ifconfig  | grep 'inet addr:'| grep -v '127.0.0.1' |head -n1 | cut -d: -f2 | awk '{ print $1}'`.chomp("\n")
uri_ip="druby://#{my_ip}:#{uri_port}"
c.log("Controller started at #{uri_ip}")
registrar=Registrar.new(c)
registrar_drb=DRb.start_service nil, registrar
registrar_uri=registrar_drb.uri
puts  "registrar uri: #{registrar_uri}"

Signal.trap("INT"){ 
    registrar_drb.stop_service
    c.shutdown(2) 
}
Signal.trap("TERM"){ 
    registrar_drb.stop_service
    c.shutdown(15) 
}
# this one does not actually generally catch kill -9 
Signal.trap("KILL"){ 
    registrar_drb.stop_service
    c.shutdown(9) 
}

# reload modules
Signal.trap("USR1"){
    c.log "reloading modules.."
    load "#{$REV_TR_TOOL_DIR}/spoofed_traceroute.rb"
    load "#{$REV_TR_TOOL_DIR}/traceroute.rb"
    load "#{$REV_TR_TOOL_DIR}/spoofed_ping.rb"
    load "#{$REV_TR_TOOL_DIR}/ping.rb"
}

## mem usage
Signal.trap("USR2") {}

#  mem_usage = `ps -o rss= -p #{Process.pid}`.to_i
#  threads = Thread.list.map { |x| "#{x[:name]}: #{x.inspect}" }
#  c.log "CAUGHT SIG USR2: #{mem_usage} KB, #{ObjectSpace.count_objects.inspect}, Threads (#{threads.size}): #{threads.inspect}"
#  if mem_usage.to_i > 170000
#    ObjectSpace.each_object(String) do |s|
#       c.logs s
#    end
#  end
#  $stderr.flush
#}

# stack dump
Signal.trap("ALRM") {}
#  fork do
#    ObjectSpace.each_object(Thread) do |th|
#      th.raise Exception, "Stack Dump" unless Thread.current == th
#    end
#    raise Exception, "Stack Dump"
#  end
#end

registrar_uri_port=registrar_uri.chomp("\n").split("/").at(-1).split(":").at(1)
registrar_uri_port=registrar_uri.chomp("\n").split("/").at(-1).split(":").at(1)
registrar_uri_ip="druby://#{my_ip}:#{registrar_uri_port}"
c.log("Registrar started at #{registrar_uri_ip}")

if not options[:test]
    `mkdir -p #{$DATADIR}/uris`
    `echo #{c.ulimit} > #{$DATADIR}/controller_ulimit.txt`
    `echo #{uri_ip} > #{$DATADIR}/uris/controller.txt`
    `echo #{registrar_uri_ip} > #{$DATADIR}/uris/registrar.txt`
    `ssh #{$SERVER} "echo #{registrar_uri_ip} > ~revtr/www/vps/registrar.txt; chmod g+w ~revtr/www/vps/registrar.txt"`
    sleep 30 # sleep to give a chance for all VPs to register
    c.probe_from_all{|vp| vp.update_controller(registrar_uri_ip)}

elsif not options[:actual_test]
    # Origninally I was always running as test so that other controllers wouldn't be killed
    # Then I added this in here, which makes it a pain to /actually/ run a
    # test controller.
    ProbeController::set_server_uri(:controller,c.uri)

    # XXX Colin's HACK
    `echo #{uri_ip} > #{$DATADIR}/uris/controller.txt`
    `echo #{registrar_uri_ip} > #{$DATADIR}/uris/registrar.txt`
    `ssh #{$SERVER} "echo #{registrar_uri_ip} > ~revtr/www/vps/isolation_registrar.txt; chmod g+w ~revtr/www/vps/isolation_registrar.txt"`
elsif options[:actual_test]
    `echo #{uri_ip} > #{$DATADIR}/uris/test_controller.txt`
    `echo #{registrar_uri_ip} > #{$DATADIR}/uris/test_registrar.txt`
    `ssh #{$SERVER} "echo #{registrar_uri_ip} > ~revtr/www/vps/test_isolation_registrar.txt; chmod g+w ~revtr/www/vps/test_isolation_registrar.txt"`
end

# wait for the DRb service to finish before exiting
DRb.thread.join
c.drb.thread.join
registrar_drb.thread.join
