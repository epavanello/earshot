#!/bin/bash
# Plays the queued spoken lines oldest first: all of them, with --one [session] only the next (the
# Play shortcut: of that session, else of the session you last talked to, else of any), or with
# --only <entry> that one queue entry alone.
# Before a line it says which session it comes from, unless you are looking at that session (Claude
# Desktop in front, its tab open) or the line before was from the same one.
# Only one player runs at a time (the lock directory holds its pid).
# EARSHOT_TMP and EARSHOT_SAY move the files and the speech command aside, for tests.
T="${EARSHOT_TMP:-/tmp}"
# earshot's own speaker (speaker/main.swift, built on first use) writes word-by-word progress for the
# inline player; without swiftc it is the system `say`.
SAY="${EARSHOT_SAY:-$("$(cd "$(dirname "$0")/.." && pwd)/speaker/build.sh")}"
SAY="${SAY:-say}"
QUEUE=$T/earshot.queue
LOCK=$T/earshot.player
SPEAKING=$T/earshot.speaking
LAST_LABEL=$T/earshot.last-label
# Esc (stop this line, keep the queue) and Play pressed while speaking (go on to the next line).
STOP=$T/earshot.stop
SKIP=$T/earshot.skip
PAUSE=0.6
HERE_SCRIPT="$(cd "$(dirname "$0")" && pwd)/here-session.sh"
UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

case "$(defaults read -g AppleLanguages 2>/dev/null | sed -n 2p)" in
  *\"it*) FROM="Da" ;;
  *) FROM="From" ;;
esac

# A chime when lines are still waiting after this player stops: the Play shortcut has more.
chime_if_more() {
  [ -n "$(ls "$QUEUE" 2>/dev/null)" ] && afplay "${EARSHOT_CHIME:-/System/Library/Sounds/Glass.aiff}" >/dev/null 2>&1
}

is_cut() {
  [ -e "$STOP" ] || [ -e "$SKIP" ] || [ ! -e "$SPEAKING" ]
}

claim() {
  mkdir "$LOCK" 2>/dev/null && echo $$ >"$LOCK/pid" && return 0
  # A player that died (killed, reboot) leaves its lock behind: take it over.
  local pid
  pid="$(cat "$LOCK/pid" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 1; fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null && echo $$ >"$LOCK/pid"
}

# The speed picked in the inline player (a multiplier, ~/.config/earshot/speed) scales the base rate.
# Args: <text> [offset], the offset (where to start) only for earshot's own speaker.
speak() {
  local speed rate
  speed="$(cat "$HOME/.config/earshot/speed" 2>/dev/null)"
  rate="$(awk -v base="${EARSHOT_VOICE_RATE:-185}" -v speed="${speed:-1}" 'BEGIN { printf "%d", base * (speed > 0 ? speed : 1) }')"
  local args=(-r "$rate")
  [ -n "$EARSHOT_VOICE" ] && args+=(-v "$EARSHOT_VOICE")
  case "$SAY" in */speaker/say) [ -n "$2" ] && args+=(--offset "$2") ;; esac
  "$SAY" "${args[@]}" "$1"
}

release() {
  rm -f "$SPEAKING"
  rm -rf "$LOCK"
}

# You are dictating (the AirPods remote's flags: its own recording, or the mic in use with Claude in
# front during the last moments): hold the line until the mic is free, rather than talk over you.
is_dictating() {
  [ -e "$T/earshot.recording" ] && return 0
  [ -e "$T/earshot.mic-used" ] && [ $(($(date +%s) - $(stat -f %m "$T/earshot.mic-used"))) -le 1 ]
}

# The next entry for --one: the asked session's, else the one you are looking at in Claude Desktop,
# else the one you last wrote to, else the oldest of all.
next_one() {
  local session="${1:-$("$HERE_SCRIPT")}" found=""
  [ -z "$session" ] && session="$(cat "$T/earshot.active-session" 2>/dev/null)"
  [ -n "$session" ] && found="$(ls "$QUEUE" 2>/dev/null | grep -F -- "-$session.txt" | sort | head -n 1)"
  [ -z "$found" ] && [ -z "$1" ] && found="$(ls "$QUEUE" 2>/dev/null | sort | head -n 1)"
  printf '%s' "$found"
}

# Another player is speaking: --one (the Play shortcut, pressed again) cuts its line short and has it
# go on with the next one, as --one would pick it.
if ! claim; then
  if [ "$1" = "--one" ] && [ -e "$SPEAKING" ]; then
    touch "$SKIP"
    pkill -x "$(basename "$SAY")"
  fi
  exit 0
fi
rm -f "$SKIP" "$STOP"
MODE="$1"
ARG="$2"
PLAYED=0
while :; do
  if [ "$MODE" = "--only" ]; then
    NEXT=""
    [ "$PLAYED" -eq 0 ] && [ -e "$QUEUE/$ARG" ] && NEXT="$ARG"
  elif [ "$MODE" = "--one" ]; then
    NEXT=""
    [ "$PLAYED" -eq 0 ] && NEXT="$(next_one "$ARG")"
  else
    NEXT="$(ls "$QUEUE" 2>/dev/null | sort | head -n 1)"
  fi
  if [ -z "$NEXT" ]; then
    release
    # A line queued after the check above and before the lock was released: play it.
    [ -z "$MODE" ] && [ -n "$(ls "$QUEUE" 2>/dev/null)" ] && claim && continue
    # A single line was read (Play, a replay, a reply of the session in view): say if more waits.
    [ "$PLAYED" -ge 1 ] && chime_if_more
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
  # Looking at this line's session: no title, and the next one from elsewhere gets it again.
  LINE_SESSION="$(printf '%s' "$NEXT" | grep -oE "$UUID" | tail -n 1)"
  if [ -n "$LINE_SESSION" ] && [ "$LINE_SESSION" = "$("$HERE_SCRIPT")" ]; then
    rm -f "$LAST_LABEL"
  elif [ -n "$LABEL" ] && [ "$LABEL" != "$(cat "$LAST_LABEL" 2>/dev/null)" ]; then
    speak "$FROM $LABEL."
    echo "$LABEL" >"$LAST_LABEL"
    is_cut || sleep 0.3
  fi
  # A replay from a word (the inline player) names its offset in the entry: -at<offset>-.
  OFFSET="$(printf '%s' "$NEXT" | sed -nE 's/.*-at([0-9]+)-.*/\1/p')"
  is_cut || speak "$TEXT" "$OFFSET"
  PLAYED=$((PLAYED + 1))
  # Esc: this line is dropped, the rest stays queued for the Play shortcut; a chime says some is left.
  if [ -e "$STOP" ]; then
    rm -f "$STOP"
    release
    chime_if_more
    exit 0
  fi
  # Play pressed again: on to the next line (reading the whole queue, it goes on anyway; a single
  # line, it picks one more as --one picks it).
  if [ -e "$SKIP" ]; then
    rm -f "$SKIP"
    [ "$MODE" = "--only" ] && MODE=--one && ARG=""
    PLAYED=0
  fi
done
