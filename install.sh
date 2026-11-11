#!/bin/bash
# Installs Claude Usage (the desktop pet) into ~/Applications and opens it.
#   curl -fsSL https://raw.githubusercontent.com/yinuochenone/claude-desktop-pet/main/install.sh | bash
set -euo pipefail

URL="https://github.com/yinuochenone/claude-desktop-pet/releases/latest/download/Claude-Usage.zip"
DEST="${INSTALL_DIR:-$HOME/Applications}"
APP="$DEST/Claude Usage.app"

major=$(sw_vers -productVersion | cut -d. -f1)
if (( major < 13 )); then
  echo "Claude Usage needs macOS 13 or newer (you have $(sw_vers -productVersion))." >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "✦ Downloading Claude Usage…"
curl -fsSL "$URL" -o "$tmp/app.zip"
ditto -x -k "$tmp/app.zip" "$tmp"

pkill -x ClaudeUsage 2>/dev/null || true
mkdir -p "$DEST"
if [[ -e "$APP" ]]; then  # an older copy goes to the Trash, not deleted
  mv "$APP" "$HOME/.Trash/Claude Usage $(date +%Y%m%d-%H%M%S).app"
fi
mv "$tmp/Claude Usage.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

open "$APP"
echo "✦ Installed: $APP"
echo "  Look for ✦ in your menu bar. Your pet is asleep in its bed in a corner of your screen."
if [[ ! -d "$HOME/.claude" ]]; then
  echo "  Tip: install Claude Code and sign in (run: claude) so the pet can show your usage."
fi
