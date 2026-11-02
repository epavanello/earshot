#!/bin/bash
# Plays the queued spoken lines one after another, oldest first, then exits.
# Only one player runs at a time (the lock directory holds its pid); speak.sh starts it.
QUEUE=/tmp/earshot.queue
LOCK=/tmp/earshot.player
SPEAKING=/tmp/earshot.speaking

claim() {
  mkdir "$LOCK" 2>/dev/null && echo $$ >"$LOCK/pid" && return 0
  # A player that died (killed, reboot) leaves its lock behind: take it over.
  local pid
  pid="$(cat "$LOCK/pid" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 1; fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null && echo $$ >"$LOCK/pid"
}

claim || exit 0
while :; do
  NEXT="$(ls "$QUEUE" 2>/dev/null | sort | head -n 1)"
  if [ -z "$NEXT" ]; then
    rm -f "$SPEAKING"
    rm -rf "$LOCK"
    # A line queued after the check above and before the lock was released: play it.
    [ -n "$(ls "$QUEUE" 2>/dev/null)" ] && claim && continue
    exit 0
  fi
  FILE="$QUEUE/$NEXT"
  TEXT="$(cat "$FILE" 2>/dev/null)"
  rm -f "$FILE"
  [ -z "$TEXT" ] && continue
  # Tells the AirPods remote to grab clicks so any click can stop the speech.
  touch "$SPEAKING"
  ARGS=(-r "${EARSHOT_VOICE_RATE:-185}")
  [ -n "$EARSHOT_VOICE" ] && ARGS+=(-v "$EARSHOT_VOICE")
  say "${ARGS[@]}" "$TEXT"
done
