#!/usr/bin/env bash
# agent-inbox Mac watcher install: run once on the developer's Mac.
#
#   ./install-mac-watcher.sh <name> [bot-token-secret]
#
# 1. Caches the developer's Discord bot token + channel id from Key Vault/API
# 2. Installs a launchd agent that runs watch-mac.sh forever (survives reboot)
set -euo pipefail

NAME="${1:?usage: install-mac-watcher.sh <name> [bot-token-secret]}"
BOT_SECRET="${2:-discord-bot-token-$NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/watch-mac.sh"
CONF_DIR="$HOME/.agent-inbox"
GUILD=1462642831184232584
LABEL="com.ideaplaces.agent-inbox-watcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ "$(uname)" = "Darwin" ] || { echo "Mac only"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v az >/dev/null || { echo "az is required"; exit 1; }
chmod +x "$WATCH"
mkdir -p "$CONF_DIR" "$HOME/Library/LaunchAgents"

echo "Fetching bot token ($BOT_SECRET) from Key Vault..."
az keyvault secret show --vault-name kv-ideaplaces --name "$BOT_SECRET" --query value -o tsv > "$CONF_DIR/bot-token"
chmod 600 "$CONF_DIR/bot-token"

echo "Resolving channel #agent-inbox-$NAME..."
CHANNEL_ID=$(curl -s -H "Authorization: Bot $(cat "$CONF_DIR/bot-token")" \
  "https://discord.com/api/v10/guilds/$GUILD/channels" \
  | jq -r --arg n "agent-inbox-$NAME" '.[] | select(.name==$n) | .id')
[ -n "$CHANNEL_ID" ] || { echo "channel agent-inbox-$NAME not found — run setup-user.sh first"; exit 1; }
echo "$CHANNEL_ID" > "$CONF_DIR/channel-id"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$WATCH</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$CONF_DIR/watcher.log</string>
  <key>StandardErrorPath</key><string>$CONF_DIR/watcher.log</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "Watcher installed and running (launchd: $LABEL, log: $CONF_DIR/watcher.log)"
echo "New messages in #agent-inbox-$NAME now raise native macOS notifications."
