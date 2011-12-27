#!/bin/bash

# When making changes to modules, we don't want to have to restart the
# controller. This sends a signal to the controller which causes it to
# dynamically reload its modules.

pkill -SIGUSR1 -f controller.rb
