#!/usr/bin/ruby -w

if ARGV.empty?
    file = "filtered.txt"
    system "grep FAILED ../isolation.log > filtered.txt"
else 
    file = ARGV.shift
end

counts = Hash.new(0)

File.foreach(file) do |line|
    hash_string = line.split(")")[1][2..-1]
    hash = {}
    begin
        hash = eval(hash_string)
    rescue SyntaxError => e
        $stderr.puts  e
        next
    end

    hash.each do |k,v|
        counts[k] += 1 if v
    end
end

puts counts.inspect
