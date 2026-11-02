#!/bin/bash
# Prints "yes" when the prompt just sent was dictated: the AirPods remote touches the flag while the
# mic is in use with Claude in front. The flag is consumed, so a typed prompt right after is not.
FLAG=/tmp/earshot.mic-used
WINDOW="${EARSHOT_DICTATION_WINDOW:-30}"
[ -e "$FLAG" ] || { echo no; exit 0; }
AGE=$(($(date +%s) - $(stat -f %m "$FLAG")))
rm -f "$FLAG"
[ "$AGE" -le "$WINDOW" ] && echo yes || echo no
