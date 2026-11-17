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
# Sorts before every timestamped entry; a player still busy plays it next.
AT=""
[ "$2" = "--text" ] && [ -n "$4" ] && AT="-at$4"
ENTRY="0-replay-$$$AT-$1.txt"
# No title announcement: you asked for this line.
{ echo; printf '%s' "$LINE"; } >"$QUEUE/$ENTRY"
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
