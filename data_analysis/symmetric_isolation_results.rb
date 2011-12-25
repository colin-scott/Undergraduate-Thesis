#!/homes/network/revtr/ruby-upgrade/bin/ruby
$: << File.expand_path("../")

require 'log_iterator'
require 'mkdot'
require 'hops'

total = 0
dst_tr_working = 0
dst_spoofed_tr_working = 0
dst_tr_passed = 0
dst_spoofed_tr_passed = 0
passed = 0

cases_of_interest = []

# TODO: encapsulate all of these data items into a single object!
LogIterator::symmetric_iterate do  |file, src, dst, dataset, direction, formatted_connected, 
                                          formatted_unconnected, pings_towards_src,
                                          tr, spoofed_tr,
                                          dst_tr, dst_spoofed_tr,
                                          historical_tr, historical_trace_timestamp,
                                          spoofed_revtr, historical_revtr,
                                          suspected_failure, as_hops_from_dst, as_hops_from_src, 
                                          alternate_paths, measured_working_direction, path_changed,
                                          measurement_times, passed_filters|
    # next unless passed_filters
    total += 1
    passed += 1 if passed_filters

    if dst_tr.valid?
        dst_tr_working += 1 
        dst_tr_passed += 1 if passed_filters
    end

    if dst_spoofed_tr.valid?
        dst_spoofed_tr_working += 1
        dst_spoofed_tr_passed += 1 if passed_filters
    end

    cases_of_interest << file if passed_filters && (dst_tr.valid? || dst_spoofed_tr.valid?)

    if passed_filters && (dst_tr.valid? || dst_spoofed_tr.valid?)
        jpg_output = "#{FailureIsolation::DotFiles}/#{File.basename(file).gsub(/yml$/, "jpg")}"
        Dot::generate_jpg(src, dst, direction, dataset, tr, spoofed_tr,
             historical_tr, spoofed_revtr, historical_revtr, jpg_output)
    end
end

puts "total: #{total}"
puts "passed: #{passed}"
puts "dst_tr_working: #{dst_tr_working} #{dst_tr_working*1.0/total}"
puts "dst_spoofed_tr_working: #{dst_spoofed_tr_working} #{dst_spoofed_tr_working*1.0/total}"
puts "dst_tr_passed: #{dst_tr_passed} #{dst_tr_passed*1.0/passed}"
puts "dst_spoofed_tr_passed: #{dst_spoofed_tr_passed} #{dst_spoofed_tr_passed*1.0/passed}"
puts cases_of_interest
