#!/bin/bash
LABEL="com.github.epavanello.earshot-remote"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/share/earshot/earshot-remote"
echo "Uninstalled."
