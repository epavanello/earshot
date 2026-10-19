#!/bin/bash
# Builds the AirPods remote and runs it at login as a LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"
LABEL="com.github.epavanello.earshot-remote"
BIN_DIR="$HOME/.local/share/earshot"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

command -v hs >/dev/null || { echo "Hammerspoon CLI 'hs' not found: install Hammerspoon, grant it Accessibility, add require('hs.ipc') to ~/.hammerspoon/init.lua"; exit 1; }
mkdir -p "$BIN_DIR"
swiftc -O main.swift -o "$BIN_DIR/earshot-remote" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$BIN_DIR/earshot-remote</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>/tmp/earshot-remote.log</string>
<key>StandardErrorPath</key><string>/tmp/earshot-remote.log</string>
</dict></plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Log: /tmp/earshot-remote.log"
