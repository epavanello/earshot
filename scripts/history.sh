#!/bin/bash
# Prints a session's spoken lines for the Voice pane, newest first, as JSON:
# {"total": n, "items": [{"id", "at", "text"}]}. Args: <session id> <how many>.
exec python3 -I - "$HOME/.config/earshot/history/$1" "${2:-10}" <<'PY'
import json, os, sys
folder, limit = sys.argv[1], int(sys.argv[2])
try:
    names = sorted((n for n in os.listdir(folder) if n.endswith(".txt")), reverse=True)
except OSError:
    names = []
items = []
for name in names[:limit]:
    try:
        with open(os.path.join(folder, name), errors="ignore") as entry:
            text = entry.read().partition("\n")[2]
    except OSError:
        continue
    try:
        at = float(name.split("-", 1)[0])
    except ValueError:
        at = 0
    items.append({"id": name, "at": at, "text": text.strip()})
print(json.dumps({"total": len(names), "items": items}))
PY
