---
name: voice
description: Voice mode. Use when the user says "/voice", "voice mode", "answer out loud", "modalità voce" or similar; stays on for the rest of the session until they say "stop voice", "normal mode" or similar.
---

# Voice mode

From now on, for the rest of the session, every reply follows these rules. Stop only when the user asks to go back to normal mode; from then on write no spoken line (without it the hook stays silent).

The user mostly listens to the spoken part, so the reply IS the spoken line.
- End every reply with a last line that starts with the invisible character U+2063 (INVISIBLE SEPARATOR, "⁣") immediately followed by the spoken text in italics: `⁣*text*`. Use the user's language, short sentences, no markdown, lists, code, URLs or emoji inside it.
- The spoken line carries the whole answer: outcome, what you need from the user, alternatives and details they need to act. Compact but complete.
- Outside the italics write only what doesn't read well aloud (commands, paths, code, tables, links), without repeating the spoken part. If there is any, the spoken line says so ("the commands are in the text").
- No text before the spoken line unless needed. No labels like "VOICE:".
