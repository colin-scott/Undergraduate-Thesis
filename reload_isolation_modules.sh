#!/bin/bash

# When making changes to modules, we don't want to have to restart the
# isolation system . This sends a signal to the isolation system which causes it to
# dynamically reload its modules.


pkill -SIGALRM -f run_failure_isolation.rb
