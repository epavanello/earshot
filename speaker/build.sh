#!/bin/bash
# Builds earshot's speaker (speaker/main.swift) into ~/.local/share/earshot/speaker/say when it is
# missing or older than its source; prints the binary's path, or nothing when it can't be built
# (no swiftc: the player falls back to the system `say`, without word-by-word progress).
SRC="$(cd "$(dirname "$0")" && pwd)/main.swift"
BIN="$HOME/.local/share/earshot/speaker/say"
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  command -v swiftc >/dev/null || exit 0
  mkdir -p "$(dirname "$BIN")"
  swiftc -O "$SRC" -o "$BIN.tmp" >/dev/null 2>&1 && mv "$BIN.tmp" "$BIN" || { rm -f "$BIN.tmp"; exit 0; }
fi
echo "$BIN"
