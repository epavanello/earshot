#!/bin/bash
# Stop hook: reads aloud the reply's spoken line (a line starting with U+2063, usually in italics).
# Silent when the reply has no such line, i.e. when voice mode is off.
# Optional env (read by player.sh): EARSHOT_VOICE (a `say -v '?'` voice name), EARSHOT_VOICE_RATE (words per minute).
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
# Lines from several sessions queue up instead of cutting each other off: each one is a file,
# named so they sort by arrival, and a single player reads them aloud in order.
QUEUE=/tmp/earshot.queue
mkdir -p "$QUEUE"
printf '%s' "$TEXT" >"$QUEUE/$(perl -MTime::HiRes=time -e 'printf "%.6f", time')-$$.txt"
# New session: otherwise Claude Code kills the hook's process group and cuts the audio.
perl -MPOSIX -e 'fork and exit; POSIX::setsid(); exec @ARGV' "${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}/scripts/player.sh" </dev/null >/dev/null 2>&1
exit 0
