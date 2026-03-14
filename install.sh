#!/bin/bash
# claudetop installer
# Copies claudetop.sh to ~/.claude/ and configures the status line

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/claudetop.sh"
PLUGIN_DIR="$HOME/.claude/claudetop.d"
SETTINGS="$HOME/.claude/settings.json"

echo "Installing claudetop..."

# 1. Copy main script
cp "$SCRIPT_DIR/claudetop.sh" "$DEST"
chmod +x "$DEST"
echo "  Copied claudetop.sh -> $DEST"

# 2. Create plugin directory
mkdir -p "$PLUGIN_DIR"
echo "  Created plugin directory: $PLUGIN_DIR"

# 3. Copy bundled plugins (only git-branch is enabled by default)
cp "$SCRIPT_DIR/plugins/git-branch.sh" "$PLUGIN_DIR/"
chmod +x "$PLUGIN_DIR/git-branch.sh"
echo "  Enabled plugin: git-branch"

# 4. Copy example plugins to _examples/
mkdir -p "$PLUGIN_DIR/_examples"
for f in "$SCRIPT_DIR/plugins/examples/"*.sh; do
  [ -f "$f" ] || continue
  cp "$f" "$PLUGIN_DIR/_examples/"
  chmod +x "$PLUGIN_DIR/_examples/$(basename "$f")"
done
echo "  Copied example plugins to $PLUGIN_DIR/_examples/"

# 5. Configure settings.json
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi

if grep -q '"statusLine"' "$SETTINGS" 2>/dev/null; then
  echo ""
  echo "  Warning: statusLine already configured in $SETTINGS"
  echo "  To use claudetop, update it manually to:"
  echo '    "statusLine": { "type": "command", "command": "~/.claude/claudetop.sh", "padding": 1 }'
else
  # Use jq to add statusLine config (or python as fallback)
  if command -v jq &>/dev/null; then
    TMP=$(mktemp)
    jq '. + {"statusLine": {"type": "command", "command": "~/.claude/claudetop.sh", "padding": 1}}' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    echo "  Configured statusLine in $SETTINGS"
  else
    echo ""
    echo "  jq not found. Add this to your $SETTINGS manually:"
    echo '    "statusLine": { "type": "command", "command": "~/.claude/claudetop.sh", "padding": 1 }'
  fi
fi

echo ""
echo "Done! Restart Claude Code to see claudetop in action."
echo ""
echo "To enable more plugins, copy from $PLUGIN_DIR/_examples/:"
echo "  cp $PLUGIN_DIR/_examples/spotify.sh $PLUGIN_DIR/"
echo "  cp $PLUGIN_DIR/_examples/weather.sh $PLUGIN_DIR/"
