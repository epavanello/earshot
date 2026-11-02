#!/bin/bash
# Plays the queued spoken lines oldest first: all of them, with --one only the next (the Play shortcut),
# or with --only <entry> that one queue entry alone.
# Before a line from another session than the last one heard it says which session it comes from.
# Only one player runs at a time (the lock directory holds its pid).
QUEUE=/tmp/earshot.queue
LOCK=/tmp/earshot.player
SPEAKING=/tmp/earshot.speaking
LAST_LABEL=/tmp/earshot.last-label
PAUSE=0.6

case "$(defaults read -g AppleLanguages 2>/dev/null | sed -n 2p)" in
  *\"it*) FROM="Da" ;;
  *) FROM="From" ;;
esac

claim() {
  mkdir "$LOCK" 2>/dev/null && echo $$ >"$LOCK/pid" && return 0
  # A player that died (killed, reboot) leaves its lock behind: take it over.
  local pid
  pid="$(cat "$LOCK/pid" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 1; fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null && echo $$ >"$LOCK/pid"
}

speak() {
  local args=(-r "${EARSHOT_VOICE_RATE:-185}")
  [ -n "$EARSHOT_VOICE" ] && args+=(-v "$EARSHOT_VOICE")
  say "${args[@]}" "$1"
}

release() {
  rm -f "$SPEAKING"
  rm -rf "$LOCK"
}

# You are dictating (the AirPods remote's flags: its own recording, or the mic in use with Claude in
# front during the last moments): hold the line until the mic is free, rather than talk over you.
is_dictating() {
  [ -e /tmp/earshot.recording ] && return 0
  [ -e /tmp/earshot.mic-used ] && [ $(($(date +%s) - $(stat -f %m /tmp/earshot.mic-used))) -le 1 ]
}

claim || exit 0
PLAYED=0
while :; do
  if [ "$1" = "--only" ]; then
    NEXT=""
    [ "$PLAYED" -eq 0 ] && [ -e "$QUEUE/$2" ] && NEXT="$2"
  else
    NEXT="$(ls "$QUEUE" 2>/dev/null | sort | head -n 1)"
  fi
  if [ -z "$NEXT" ] || { [ "$1" = "--one" ] && [ "$PLAYED" -ge 1 ]; }; then
    release
    # A line queued after the check above and before the lock was released: play it.
    [ -z "$1" ] && [ -n "$(ls "$QUEUE" 2>/dev/null)" ] && claim && continue
    exit 0
  fi
  FILE="$QUEUE/$NEXT"
  LABEL="$(head -n 1 "$FILE" 2>/dev/null)"
  TEXT="$(tail -n +2 "$FILE" 2>/dev/null)"
  rm -f "$FILE"
  [ -z "$TEXT" ] && continue
  while is_dictating; do sleep 0.5; done
  # Tells the AirPods remote to grab clicks so any click can stop the speech.
  touch "$SPEAKING"
  [ "$PLAYED" -ge 1 ] && sleep "$PAUSE"
  if [ -n "$LABEL" ] && [ "$LABEL" != "$(cat "$LAST_LABEL" 2>/dev/null)" ]; then
    speak "$FROM $LABEL."
    echo "$LABEL" >"$LAST_LABEL"
    sleep 0.3
  fi
  # Esc or a click empties the queue while speaking: stop here rather than read the line.
  [ -e "$SPEAKING" ] && speak "$TEXT"
  PLAYED=$((PLAYED + 1))
done
