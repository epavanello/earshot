#!/bin/bash
# Stop hook: reads aloud the reply's spoken line (a line starting with U+2063, usually in italics).
# Silent when the reply has no such line, i.e. when voice mode is off.
# Optional env: EARSHOT_VOICE (a `say -v '?'` voice name), EARSHOT_VOICE_RATE (words per minute).
TEXT="$(python3 -I -c '
import sys, json, re
try:
    msg = json.load(sys.stdin).get("last_assistant_message") or ""
    m = re.findall(r"^\s*⁣[*_]*\s*(.+?)\s*[*_]*\s*$", msg, re.M)
    print(m[-1].strip() if m else "")
except Exception:
    print("")
')"
[ -z "$TEXT" ] && exit 0
# The AirPods remote is recording a new message: this reply is already stale.
[ -e /tmp/earshot.recording ] && exit 0
pkill -x say 2>/dev/null
ARGS=(-r "${EARSHOT_VOICE_RATE:-185}")
[ -n "$EARSHOT_VOICE" ] && ARGS+=(-v "$EARSHOT_VOICE")
# New session: otherwise Claude Code kills the hook's process group and cuts the audio.
perl -MPOSIX -e 'fork and exit; POSIX::setsid(); exec @ARGV' say "${ARGS[@]}" "$TEXT" </dev/null >/dev/null 2>&1
exit 0
