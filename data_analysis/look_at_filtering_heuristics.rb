#!/usr/bin/ruby -w

system "grep FAILED ../isolation.log > filtered.txt"

counts = Hash.new(0)

File.foreach("filtered.txt") do |line|
    hash_string = line.split(")")[1][2..-1]
    hash = {}
    begin
        hash = eval(hash_string)
    rescue SyntaxError
        next
    end

    hash.each do |k,v|
        counts[k] += 1 if v
    end
end

puts counts.inspect
