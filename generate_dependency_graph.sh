#!/bin/bash

# Regenerate rdoc for the isolation system

# We want just isolation code, so check out the repo
cd /tmp
rm -rf spoofed_traceroute
svn co svn+ssh://revtr@slider.cs.washington.edu/homes/network/revtr/ugrad_svn/spoofed_traceroute
cd spoofed_traceroute

~revtr/ruby-upgrade/bin/depgraph -type ruby_requires -trans
mv dependency_graph.png ~revtr/www/rdoc/
echo "results in ~revtr/www/rdoc/"
