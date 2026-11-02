#!/bin/bash
# Prints how a new spoken line is delivered: "now" (read at once) or "ask" (chime, wait for Play).
# The Voice pane writes ~/.config/earshot/mode: off | auto | now | ask. Without the pane (the skill
# alone) or with the switch off, lines are read at once as before. "auto" reads at once when the
# default output is a pair of AirPods (they are in your ears) and waits otherwise.
MODE="$(cat "$HOME/.config/earshot/mode" 2>/dev/null)"
case "$MODE" in
  ask) echo ask ;;
  auto)
    OUTPUT="$(system_profiler SPAudioDataType -json 2>/dev/null | python3 -I -c '
import json, sys
try:
    for item in json.load(sys.stdin)["SPAudioDataType"][0]["_items"]:
        if item.get("coreaudio_default_audio_output_device") == "spaudio_yes":
            print(item["_name"])
except Exception:
    pass
')"
    case "$OUTPUT" in *AirPods*) echo now ;; *) echo ask ;; esac
    ;;
  *) echo now ;;
esac
