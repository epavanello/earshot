#!/bin/bash
# Esc or an AirPods click while speaking: drops the line being read, keeps the rest of the queue
# for the Play shortcut.
touch /tmp/earshot.stop
rm -f /tmp/earshot.speaking
pkill -x say
exit 0
