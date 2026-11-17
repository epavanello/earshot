#!/bin/bash
# The inline player's Pause / Resume: toggles the line being read by earshot's speaker, at the next
# word (it keeps its pid in the progress file).
python3 -I - "${EARSHOT_TMP:-/tmp}/earshot.progress" <<'PY'
import json, os, signal, sys
try:
    with open(sys.argv[1]) as f:
        progress = json.load(f)
    if progress.get("state") in ("speaking", "paused"):
        os.kill(int(progress["pid"]), signal.SIGUSR1)
except Exception:
    pass
PY
exit 0
