#!/bin/bash

# Restart both the controller and the isolation system

pkill -9 -f controller.rb
pkill -9 -f run_failure_isolation.rb
sleep 2
../monitoring_tasks/check_on_monitoring_processes.sh
sleep 2
~/jruby/bin/jruby -J-Xmx3g ./restart_vps.rb
