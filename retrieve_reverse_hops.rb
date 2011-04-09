#!/homes/network/revtr/ruby/bin/ruby

# We harvest forward hops (for checking pingability) from toil. 
# We also want to know historical pingability for reverse hops.
# This is a hack... this is executed from toil, /after/
# ~/colin/ping_monitoring/cloudfront_montoring/data_w_traceroutes/hand_forward_hops_to_dave.sh
# has been executed. We simply append reverse hops onto the previous_week.txt
# file.

require 'db_interface'
require 'set'

$forward_hops_file = "/homes/network/revtr/failure_isolation/pingability/previous_week.txt"

forward_hops = Set.new(IO.read($forward_hops_file).split("\n"))
db = DatabaseInterface.new
reverse_hops = db.fetch_reverse_hops
#$stderr.puts reverse_hops.inspect
forward_hops |= reverse_hops

File.open($forward_hops_file, "w") { |f| f.puts forward_hops.to_a.join("\n") }
