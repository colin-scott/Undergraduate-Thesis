#!/bin/bash

pkill -9 -f controller.rb
pkill -9 -f run_failure_isolation.rb
sleep 2
../monitoring_tasks/check_on_monitoring_processes.sh
sleep 2
./restart_vps.rb
