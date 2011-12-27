#!/bin/bash

# Regenerate rdoc for the isolation system

# We want just isolation code, so check out the repo
cd /tmp
rm -rf spoofed_traceroute
svn co svn+ssh://revtr@slider.cs.washington.edu/homes/network/revtr/ugrad_svn/spoofed_traceroute
cd spoofed_traceroute

rm -rf ~/www/rdoc/isolation_system/
rdoc -o ~/www/rdoc/isolation_system/
