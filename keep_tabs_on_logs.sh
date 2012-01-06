#!/bin/bash

# Cron job. Run on yorker: `crontab -l`

# Make sure that both the controller and the isolation module are generating
# new log entries on a regular basis. If not, send out a warning email. 

old_isolation=`cat isolation_log_size`
old_controller=`cat controller_log_size`
#du -b isolation.log | cut -f1 > isolation_log_size
#du -b controller.log | cut -f1 > controller_log_size
du -b ~/revtr_logs/isolation_logs/isolation.log | cut -f1 > isolation_log_size
du -b ~/revtr_logs/isolation_logs/controller.log | cut -f1 > controller_log_size
new_isolation=`cat isolation_log_size`
new_controller=`cat controller_log_size`

if [ "$old_isolation" -eq "$new_isolation" ]; then
    echo ISOLATION_NOT_LOGGING
fi
if [ "$old_controller" -eq  "$new_controller" ]; then
    echo CONTROLLER_NOT_LOGGING
fi

EMPTY_PINGS_LOG_DIR=~/revtr_logs/isolation_logs/empty_pings_logs
rm -rf $EMPTY_PINGS_LOG_DIR/*
