#!/bin/bash
# Prints the id of the Claude Code session you are looking at: Claude Desktop in front, and of its
# sessions the one focused last (its tab or window). Prints nothing when Claude is not in front.
# Claude Desktop keeps one metadata file per session with lastFocusedAt near the top: read the head
# of those touched in the last day.
[ -n "$EARSHOT_HERE" ] && { printf '%s' "$EARSHOT_HERE"; exit 0; }
case "$(lsappinfo info -only bundleid "$(lsappinfo front)" 2>/dev/null)" in
  *com.anthropic.claudefordesktop*) ;;
  *) exit 0 ;;
esac
SESSIONS="$HOME/Library/Application Support/Claude/claude-code-sessions"
[ -d "$SESSIONS" ] || exit 0
find "$SESSIONS" -name 'local_*.json' -mtime -1 -print0 2>/dev/null | python3 -I -c '
import re, sys
best, best_at = "", -1
for path in sys.stdin.buffer.read().split(b"\0"):
    if not path:
        continue
    try:
        with open(path, "rb") as meta:
            head = meta.read(4096).decode("utf-8", "ignore")
    except OSError:
        continue
    at = re.search(r"\"lastFocusedAt\":(\d+)", head)
    session = re.search(r"\"cliSessionId\":\"([^\"]+)\"", head)
    if at and session and int(at.group(1)) > best_at:
        best, best_at = session.group(1), int(at.group(1))
print(best, end="")
'
