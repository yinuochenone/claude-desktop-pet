#!/bin/bash
# Builds "Claude Usage.app" into ~/Applications and (re)launches it.
# `./build.sh debug` adds the pet's test hooks (see the DEBUG section in src/Pet.swift).
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/Claude Usage.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

FLAGS=(-O)
[[ "${1:-}" == debug ]] && FLAGS+=(-D DEBUG)
swiftc "${FLAGS[@]}" -o "$APP/Contents/MacOS/ClaudeUsage" src/*.swift
cp src/overlay.html src/pet.html "$APP/Contents/Resources/"
cp src/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1

pkill -x ClaudeUsage 2>/dev/null || true
sleep 0.3
open "$APP"
echo "✦ running: $APP"
