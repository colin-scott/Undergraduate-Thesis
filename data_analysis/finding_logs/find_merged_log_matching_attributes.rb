#!/homes/network/revtr/ruby/bin/ruby
$: << File.expand_path("../../")

if ARGV.empty?
    $stderr.puts "please specify some attributes, in the form"
    $stderr.puts "attribute=value,attribute=value..."
    exit
end

require 'isolation_module'
require 'utilities'
require 'failure_analyzer'
require 'failure_dispatcher'
require 'log_iterator'
require 'ip_info'
require 'set'

# args are attributes
# key=value,key=value,...
attributes = ARGV.shift.split(",").map { |keyvalue| keyvalue.split("=") }.custom_to_hash

$stderr.puts "attributes: #{attributes.inspect}"

attribute_names = Set.new(attributes.keys)

# hmmm, assumes values are strings...

LogIterator::iterate do |o|
    next unless o.passed_filters

    passed_attributes = Set.new

    attributes.each do |key, value|
        if o.respond_to? key
            if  o.send(key) == value
                $stderr.puts "passed! #{o.file}"
                passed_attributes.add(key)
                break
            end
        else
            $stderr.puts "outage doesn't respond to #{key}!"
        end
    end 

    if passed_attributes.eql? attribute_names
        puts "#{FailureIsolation::IsolationResults}/#{o.file}.bin"
    end
end

