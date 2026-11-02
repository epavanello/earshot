#!/bin/bash
# Writes the delivery mode the Voice pane picked, for speak.sh and mode.sh: off | auto | now | ask.
mkdir -p "$HOME/.config/earshot"
printf '%s' "$1" >"$HOME/.config/earshot/mode"
