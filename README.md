# earshot

Talk to Claude Code and hear the answer. macOS only.

- **Spoken replies**: a `voice` skill makes Claude end each reply with a short spoken line, hidden behind an invisible marker and written in italics. A `Stop` hook reads it with the macOS `say` voice. When Claude asks with buttons (AskUserQuestion), a `PreToolUse` hook reads the question while they are on screen. With voice mode off, the hooks stay silent.
- **AirPods remote** (optional): **double-click** the stem to start Claude Desktop dictation, **pause** or **nod** to send, **click** or **Esc** to stop Claude talking. Hands and keyboard free.

> **Double click, not single.** A single click doesn't start dictation, because taking an AirPod out sends the same command as a single click.

## Install

In Claude Code:

```
/plugin marketplace add epavanello/earshot
/plugin install earshot@earshot
```

Restart Claude Code, then say "voice mode" or run `/earshot:voice`. Say "normal mode" to turn it off.

On a Claude Code build that runs plugin hooks modules, `/voice-on` and `/voice-off` switch voice with no UI (`/voice-on` brings back the last mode, Now by default). `/voice-panel` opens the **Voice** pane, which picks the mode. The mode is shared by all your sessions:

| Mode | A new reply |
| --- | --- |
| Off | no spoken line |
| Now | chimes and is read at once |
| On demand | chimes and waits in the queue |
| Auto | Now when AirPods are the output, On demand otherwise |

**Reply by voice** picks *when*: Always, or Only when dictated. Dictation (stem click, Cmd+D, the mic button) is told by the mic being in use with Claude in front during the 30 s before sending, which the AirPods remote watches, so that one needs the remote installed.

Replies from several sessions queue up and are read one after another, each introduced by its session's current title, except while you look at that session (Claude Desktop in front, its tab open; read from `lastFocusedAt` in Claude Desktop's session files). A reply of the session you look at is read at once, whatever the mode. Tap left Shift twice in any app (needs Hammerspoon) to play the next one of the session you look at, else of the one you last talked to, else the oldest of any; tap it twice again while it speaks to skip to the one after. After a single line, a chime says another is waiting. Playing a line yourself (inline player or pane) also takes it and every older line of its session out of the queue, so the shortcut doesn't read them again. Esc or an AirPods click drops the line being read and keeps the rest queued, with a chime when some is left.

The pane shows the queue of its own session and every line spoken in it, newest first, with ▶ to hear one again and *Show more* for older ones. The lines are kept in `~/.config/earshot/history/<session id>/`.

**Inline player.** In the transcript, a reply's spoken line is drawn as a small player under the reply: ▶ Play, ❚❚ Pause / ▶ Resume and ■ Stop while it is read, and a **Speed** menu (0.75× to 2×). Click any word to hear the line from there. While it is read, the word being spoken is in bold. The speed holds for every later line, in every session (`~/.config/earshot/speed`); changed while a line is read, the line goes on from the same word at the new speed. Lines are read by earshot's own speaker (`speaker/main.swift`, the same voices and rate as `say`), built on first use with `swiftc` into `~/.local/share/earshot/speaker/`; without the Xcode command line tools, `say` reads them and nothing is highlighted.

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
| Any click, or Esc, while Claude is speaking, from any app | Drops the line being read; the rest stays queued |

Single clicks don't start dictation, because taking an AirPod out sends the same command as a click. When Claude isn't speaking and another app is in front, clicks go back to your music. While you dictate, the speak hook skips the stale reply.

Debug: `mkdir -p ~/.config/earshot && touch ~/.config/earshot/debug-voice` makes the remote say each step out loud (dictation started, sent, silence, mic busy). Delete the file to turn it off.

Uninstall: `airpods/uninstall.sh`. Log: `/tmp/earshot-remote.log`.

### Why it works this way

- While the mic is on, macOS takes AirPods clicks for call mute and passes them to no app, so sending relies on silence (the mic can be shared with Claude's dictation) or a head nod read through `CMHeadphoneMotionManager`. The remote listens to the mic only while you dictate: any mic listener puts the AirPods in call mode.
- Hammerspoon presses the keys and watches for Esc, because it keeps its Accessibility permission. A locally built binary loses it on every rebuild.
- Dictation starts with a real Cmd+D tap (Cmd down, D, Cmd up). Without the Cmd key events Claude treats it as push-to-talk, which stops when Claude loses focus.

## License

MIT
