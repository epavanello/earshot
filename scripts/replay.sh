#!/bin/bash
# Reads one line of a session's history again (the Voice pane's Replay): stops what is speaking,
# puts the line first in the queue and plays it alone. Args: <session id> <history entry>, or
# <session id> --text <text> [offset] (the inline player's Play, or a click on a word: from there).
if [ "$2" = "--text" ]; then
  LINE="$3"
else
  FILE="$HOME/.config/earshot/history/$1/$2"
  [ -f "$FILE" ] || exit 0
  LINE="$(tail -n +2 "$FILE")"
fi
[ -n "$LINE" ] || exit 0
QUEUE=/tmp/earshot.queue
mkdir -p "$QUEUE"
# Only the last Play counts: earlier replays still waiting are dropped.
rm -f "$QUEUE"/0-replay-*
# Playing a line also takes it, and every older line of its session, out of the queue: you have
# caught up with that session, so the Play shortcut doesn't go back and read them (or it) again.
# The line is found by its entry (history replay) or by its text among the session's queued lines.
python3 -I - "$QUEUE" "$1" "$2" "$LINE" <<'PY'
import os, sys
queue, session, entry, line = sys.argv[1:5]
suffix = f"-{session}.txt"


def stamp(name):
    try:
        return float(name.split("-", 1)[0])
    except ValueError:
        return None


mine = sorted(n for n in os.listdir(queue) if n.endswith(suffix) and not n.startswith("0-replay-"))
cutoff = None
if entry != "--text":
    cutoff = stamp(entry)
else:
    for name in mine:
        try:
            with open(os.path.join(queue, name), errors="ignore") as f:
                body = f.read().partition("\n")[2].strip()
        except OSError:
            continue
        if body == line.strip():
            cutoff = stamp(name)
if cutoff is not None:
    for name in mine:
        if (stamp(name) or 0) <= cutoff:
            try:
                os.remove(os.path.join(queue, name))
            except OSError:
                pass
PY
# Sorts before every timestamped entry; a player still busy plays it next.
AT=""
[ "$2" = "--text" ] && [ -n "$4" ] && AT="-at$4"
ENTRY="0-replay-$$$AT-$1.txt"
# No title announcement: you asked for this line.
{ echo; printf '%s' "$LINE"; } >"$QUEUE/$ENTRY"
# A player holding the lock without speaking is waiting (dictation, the pause between lines): you
# asked for this line, so it goes.
PID="$(cat /tmp/earshot.player/pid 2>/dev/null)"
if [ -n "$PID" ] && [ ! -e /tmp/earshot.speaking ] && kill -0 "$PID" 2>/dev/null; then
  kill "$PID" 2>/dev/null
  rm -rf /tmp/earshot.player
fi
# A player speaking now: cut it short and give it a moment to let go of the lock (a player reading
# the whole queue takes this entry itself, being first).
if [ -e /tmp/earshot.speaking ]; then
  rm -f /tmp/earshot.speaking
  pkill -x say
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    { [ ! -d /tmp/earshot.player ] || [ ! -e "$QUEUE/$ENTRY" ]; } && break
    sleep 0.3
  done
fi
[ -e "$QUEUE/$ENTRY" ] || exit 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
perl -MPOSIX -e 'fork and exit; POSIX::setsid(); exec @ARGV' "$ROOT/scripts/player.sh" --only "$ENTRY" </dev/null >/dev/null 2>&1
exit 0
