#!/bin/bash
# Stop hook: queues the reply's spoken line (a line starting with U+2063, usually in italics) and,
# depending on the delivery mode, reads it aloud now or only chimes and waits for the Play shortcut.
# Silent when the reply has no such line, i.e. when voice mode is off.
# Optional env (read by player.sh): EARSHOT_VOICE (a `say -v '?'` voice name), EARSHOT_VOICE_RATE (words per minute).
INPUT="$(cat)"
TEXT="$(printf '%s' "$INPUT" | python3 -I -c '
import sys, json, re
try:
    msg = json.load(sys.stdin).get("last_assistant_message") or ""
    m = re.findall(r"^\s*⁣[*_]*\s*(.+?)\s*[*_]*\s*$", msg, re.M)
    print(m[-1].strip() if m else "")
except Exception:
    print("")
')"
[ -z "$TEXT" ] && exit 0
# The session's current title names it when the player announces where a line comes from: the last
# title the transcript holds (a rename, else the generated one), else the session's folder.
LABEL="$(printf '%s' "$INPUT" | python3 -I -c '
import sys, json, os
try:
    hook = json.load(sys.stdin)
except Exception:
    hook = {}
title = ""
try:
    found = {}
    with open(hook.get("transcript_path") or "", errors="ignore") as transcript:
        for line in transcript:
            if "-title\"" not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            for key in ("customTitle", "aiTitle"):
                if entry.get(key):
                    found[key] = entry[key]
    title = found.get("customTitle") or found.get("aiTitle") or ""
except Exception:
    pass
print(title or os.path.basename((hook.get("cwd") or "").rstrip("/")))
')"

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# Lines from several sessions queue up instead of cutting each other off: each one is a file,
# named so they sort by arrival (first line the session, then the text), read by a single player.
QUEUE=/tmp/earshot.queue
mkdir -p "$QUEUE"
ENTRY="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')-$$.txt"
printf '%s\n%s' "$LABEL" "$TEXT" >"$QUEUE/$ENTRY"

afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 &
# The reply of the session you last talked to, with Claude still in front: you are there, read it now.
# Any other session follows the mode, which may only chime and wait for Play.
SESSION="$(printf '%s' "$INPUT" | python3 -I -c 'import sys, json; print(json.load(sys.stdin).get("session_id") or "")' 2>/dev/null)"
FRONT="$(lsappinfo info -only bundleid "$(lsappinfo front)" 2>/dev/null)"
IS_HERE=no
[ -n "$SESSION" ] && [ "$SESSION" = "$(cat /tmp/earshot.active-session 2>/dev/null)" ] &&
  case "$FRONT" in *com.anthropic.claudefordesktop*) IS_HERE=yes ;; esac
[ "$IS_HERE" = no ] && [ "$("$ROOT/scripts/mode.sh")" = "ask" ] && exit 0
# Here and the mode would wait: read only this reply, ahead of what other sessions left queued.
PLAY=()
[ "$IS_HERE" = yes ] && [ "$("$ROOT/scripts/mode.sh")" = "ask" ] && PLAY=(--only "$ENTRY")
# New session: otherwise Claude Code kills the hook's process group and cuts the audio.
perl -MPOSIX -e 'fork and exit; POSIX::setsid(); exec @ARGV' "$ROOT/scripts/player.sh" "${PLAY[@]}" </dev/null >/dev/null 2>&1
exit 0
