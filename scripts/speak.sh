#!/bin/bash
# Stop hook: queues the reply's spoken line (a line starting with U+2063, usually in italics) and,
# depending on the delivery mode, reads it aloud now or only chimes and waits for the Play shortcut.
# Silent when the reply has no such line, i.e. when voice mode is off.
# PreToolUse hook on AskUserQuestion: the buttons keep the turn open until you answer, so with
# voice mode on it reads the question while they are on screen.
# Optional env (read by player.sh): EARSHOT_VOICE (a `say -v '?'` voice name), EARSHOT_VOICE_RATE (words per minute).
INPUT="$(cat)"
TEXT="$(printf '%s' "$INPUT" | python3 -I -c '
import sys, json, re


def is_voice_on(path):
    # The voice rules ride along each prompt while voice mode is on.
    with open(path, "rb") as transcript:
        transcript.seek(0, 2)
        transcript.seek(max(0, transcript.tell() - 2_000_000))
        tail = transcript.read().decode("utf-8", "ignore")
    return tail.rfind("# Voice mode") > tail.rfind("Voice mode is now off")


# Emoji, with their joiners, skin tones, variation selectors and keycap marks: `say` spells them out.
EMOJI = re.compile(
    "[\U0001F000-\U0001FAFF\u2600-\u27BF\u2B00-\u2BFF\u2300-\u23FF"
    "\U000E0020-\U000E007F\u200D\uFE0E\uFE0F\u20E3]+"
)


def speakable(text):
    return re.sub(r"\s+", " ", EMOJI.sub(" ", text)).strip()


try:
    hook = json.load(sys.stdin)
    if hook.get("hook_event_name") == "PreToolUse":
        questions = (hook.get("tool_input") or {}).get("questions") or []
        text = " ".join(question.get("question") or "" for question in questions)
        text = re.sub(r"\[([^\]]*)\]\([^)]*\)|[*_`#]", r"\1", text)
        print(speakable(text) if is_voice_on(hook["transcript_path"]) else "")
    else:
        found = re.findall(r"^\s*⁣[*_]*\s*(.+?)\s*[*_]*\s*$", hook.get("last_assistant_message") or "", re.M)
        print(speakable(found[-1]) if found else "")
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
