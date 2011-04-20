#!/usr/bin/ruby1.9 -w
$: << File.expand_path("../")

require 'delegate'
require 'forwardable'
require 'yaml'

class R

    def_delegators :@hops,:&,:*,:+,:-,:<<,:<=>,:==,:[],:[],:[]=,:abbrev,:assoc,:at,:clear,:collect,:collect!,:compact,:compact!,:concat,:delete,:delete_at,:delete_if,:each,:each_index,:empty?,:fetch,:fill,:first,:flatten,:flatten!,:frozen?,:hash,:include?,:index,:indexes,:indices,:initialize_copy,:insert,:join,:last,:length,:map,:map!,:nitems,:pack,:pop,:push,:rassoc,:reject,:reject!,:replace,:reverse,:reverse!,:reverse_each,:rindex,:select,:shift,:size,:slice,:slice!,:sort,:sort!,:to_a,:to_ary,:transpose,:uniq,:uniq!,:unshift,:values_at,:zip,:|
end

r = R.new(false)
t = R.new(true)

puts YAML.dump(r)
puts YAML.dump(t)
