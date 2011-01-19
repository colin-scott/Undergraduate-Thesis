#!/usr/bin/ruby -w

require 'drb'
require 'drb/acl'
require '../spooftr_config'

class RevtrSink
    def initialize
       acl=ACL.new(%w[deny all
					allow *.cs.washington.edu
					allow localhost
					allow 127.0.0.1
					])

		@drb=DRb.start_service nil, self, acl

	    system %{ssh #{$SERVER} "echo #{@drb.uri} > ~revtr/www/vps/failure_isolation/isolation_module.txt;\
                                 chmod g+w ~revtr/www/vps/failure_isolation/isolation_module.txt"}
        puts "DRb started at #{@drb.uri}"
    end

    def send_results(source, dest, results)
        puts "send_results(): #{source.inspect} #{dest.inspect} #{results.inspect}"
    end
end

sink = RevtrSink.new
DRb.thread.join
