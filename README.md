# earshot

Talk to Claude Code and hear the answer. macOS only.

- **Spoken replies**: a `voice` skill makes Claude end each reply with a short spoken line, hidden behind an invisible marker and written in italics. A `Stop` hook reads it with the macOS `say` voice. With voice mode off, the hook stays silent.
- **AirPods remote** (optional): **double-click** the stem to start Claude Desktop dictation, **pause** or **nod** to send, **click** or **Esc** to stop Claude talking. Hands and keyboard free.

> **Double click, not single.** A single click doesn't start dictation, because taking an AirPod out sends the same command as a single click.

## Install

In Claude Code:

```
/plugin marketplace add epavanello/earshot
/plugin install earshot@earshot
```

Restart Claude Code, then say "voice mode" or run `/earshot:voice`. Say "normal mode" to turn it off.

Optional settings (env vars, e.g. in `settings.json` → `env`):

| Variable | Default | Example |
| --- | --- | --- |
| `EARSHOT_VOICE` | system voice | `Alice (Enhanced)` (list: `say -v '?'`) |
| `EARSHOT_VOICE_RATE` | `185` | words per minute |

Tip: leave `EARSHOT_VOICE` unset and pick a Siri voice in System Settings → Accessibility → Spoken Content → System voice. It sounds far more natural than the classic voices and `say` uses it by default.

## AirPods remote

Requires Claude Desktop, AirPods with head tracking (Pro, Max, 3rd gen+), Xcode command line tools and [Hammerspoon](https://www.hammerspoon.org) with Accessibility permission and `require("hs.ipc")` in `~/.hammerspoon/init.lua`.

```
~/.claude/plugins/marketplaces/earshot/airpods/install.sh
```

(or run `airpods/install.sh` from a clone). It builds a small background app and starts it at login. Allow the Motion and Microphone permissions on first use.

| Gesture | Action |
| --- | --- |
| Stem double click, with Claude Desktop in front | Stops any speech, starts dictation (taps Cmd+D). It keeps recording if you switch apps |
| 3.5 s of silence after speaking, or chin down ~20° and back | Brings Claude to the front and sends |
| Any click, or Esc, while Claude is speaking, from any app | Stops the speech |

Single clicks don't start dictation, because taking an AirPod out sends the same command as a click. When Claude isn't speaking and another app is in front, clicks go back to your music. While you dictate, the speak hook skips the stale reply.

Debug: `mkdir -p ~/.config/earshot && touch ~/.config/earshot/debug-voice` makes the remote say each step out loud (dictation started, sent, silence, mic busy). Delete the file to turn it off.

Uninstall: `airpods/uninstall.sh`. Log: `/tmp/earshot-remote.log`.

### Why it works this way

- While the mic is on, macOS takes AirPods clicks for call mute and passes them to no app, so sending relies on silence (the mic can be shared with Claude's dictation) or a head nod read through `CMHeadphoneMotionManager`. The remote listens to the mic only while you dictate: any mic listener puts the AirPods in call mode.
- Hammerspoon presses the keys and watches for Esc, because it keeps its Accessibility permission. A locally built binary loses it on every rebuild.
- Dictation starts with a real Cmd+D tap (Cmd down, D, Cmd up). Without the Cmd key events Claude treats it as push-to-talk, which stops when Claude loses focus.

## License

MIT
