#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../")

require 'isolation_module'
require 'outage_correlation'
require 'failure_analyzer'
require 'outage'
require 'suspect_set_processors'
require 'db_interface'
require 'utilities'
Thread.abort_on_exception = true

require 'failure_dispatcher'

#controller = DRb::DRbObject.new_with_uri(FailureIsolation::ControllerUri)
#registrar = DRb::DRbObject.new_with_uri(FailureIsolation::RegistrarUri)

uri = ARGV.shift
uri ||= FailureIsolation::ControllerUri

dispatcher = FailureDispatcher.new()
hosts = DRb::DRbObject.new_with_uri(uri).hosts.sort_by { rand }.clone.find_all { |h| h.include? "bgpmux" } - ["prin.bgpmux"]

src = hosts.first

if !src.nil?
    results = dispatcher.issue_revtr(src, "74.125.224.48")

    $stderr.puts "Results: #{results.inspect}"
end
