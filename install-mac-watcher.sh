#!/usr/bin/env bash
# agent-inbox Mac watcher install: run once on the Mac that should receive
# notifications.
#
#   ./install-mac-watcher.sh --ntfy <topic>
#   ./install-mac-watcher.sh --discord <bot-token> <channel-id> [guild-id]
#   ./install-mac-watcher.sh --keyvault <name> [bot-token-secret]
#
# 1. Configures the watcher's transport under ~/.agent-inbox/
# 2. Installs a launchd agent that runs watch-mac.sh forever (survives reboot)
# 3. Links the SwiftBar plugin for the sticky menubar inbox, if SwiftBar exists
#
# --keyvault resolves the bot token from Azure Key Vault and looks up the
# channel named "agent-inbox-<name>" in AGENT_INBOX_GUILD. Set AGENT_INBOX_VAULT
# and AGENT_INBOX_GUILD (env or ~/.agent-inbox/config).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/watch-mac.sh"
CONF_DIR="$HOME/.agent-inbox"
LABEL="com.agent-inbox.watcher"
LEGACY_LABEL="com.ideaplaces.agent-inbox-watcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ "$(uname)" = "Darwin" ] || { echo "Mac only"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
chmod +x "$WATCH"
mkdir -p "$CONF_DIR" "$HOME/Library/LaunchAgents"
[ -f "$CONF_DIR/config" ] && . "$CONF_DIR/config"

usage() {
  echo "usage: install-mac-watcher.sh --ntfy <topic> | --discord <bot-token> <channel-id> [guild-id] | --keyvault <name> [bot-token-secret]" >&2
  exit 1
}

case "${1:-}" in
  --ntfy)
    TOPIC="${2:-}"; [ -n "$TOPIC" ] || usage
    printf '%s' "$TOPIC" > "$CONF_DIR/ntfy-topic"
    chmod 600 "$CONF_DIR/ntfy-topic"
    echo "ntfy transport configured (topic: $TOPIC)"
    ;;
  --discord)
    BOT_TOKEN="${2:-}"; CHANNEL_ID="${3:-}"
    [ -n "$BOT_TOKEN" ] && [ -n "$CHANNEL_ID" ] || usage
    printf '%s' "$BOT_TOKEN" > "$CONF_DIR/bot-token"; chmod 600 "$CONF_DIR/bot-token"
    printf '%s' "$CHANNEL_ID" > "$CONF_DIR/channel-id"
    [ -n "${4:-}" ] && printf '%s' "$4" > "$CONF_DIR/guild-id"
    echo "Discord transport configured (channel: $CHANNEL_ID)"
    ;;
  --keyvault)
    NAME="${2:-}"; [ -n "$NAME" ] || usage
    BOT_SECRET="${3:-discord-bot-token-$NAME}"
    VAULT="${AGENT_INBOX_VAULT:-}"; GUILD="${AGENT_INBOX_GUILD:-}"
    [ -n "$VAULT" ] && [ -n "$GUILD" ] || { echo "set AGENT_INBOX_VAULT and AGENT_INBOX_GUILD"; exit 1; }
    command -v az >/dev/null || { echo "az is required for --keyvault"; exit 1; }
    echo "Fetching bot token ($VAULT/$BOT_SECRET)..."
    az keyvault secret show --vault-name "$VAULT" --name "$BOT_SECRET" --query value -o tsv > "$CONF_DIR/bot-token"
    chmod 600 "$CONF_DIR/bot-token"
    echo "Resolving channel #agent-inbox-$NAME..."
    CHANNEL_ID=$(curl -s -H "Authorization: Bot $(cat "$CONF_DIR/bot-token")" \
      "https://discord.com/api/v10/guilds/$GUILD/channels" \
      | jq -r --arg n "agent-inbox-$NAME" '.[] | select(.name==$n) | .id')
    [ -n "$CHANNEL_ID" ] || { echo "channel agent-inbox-$NAME not found — run setup-user.sh first"; exit 1; }
    printf '%s' "$CHANNEL_ID" > "$CONF_DIR/channel-id"
    printf '%s' "$GUILD" > "$CONF_DIR/guild-id"
    ;;
  *)
    usage
    ;;
esac

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

# Retire the pre-rename agent if this machine ran an older version.
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
if [ -f "$LEGACY_PLIST" ]; then
  launchctl unload "$LEGACY_PLIST" 2>/dev/null || true
  rm -f "$LEGACY_PLIST"
fi

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "Watcher installed and running (launchd: $LABEL, log: $CONF_DIR/watcher.log)"

# Sticky menubar inbox via SwiftBar (brew install --cask swiftbar)
if [ -d "/Applications/SwiftBar.app" ]; then
  PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
  if [ -z "$PLUGIN_DIR" ]; then
    PLUGIN_DIR="$CONF_DIR/swiftbar"
    defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUGIN_DIR"
  fi
  mkdir -p "$PLUGIN_DIR"
  chmod +x "$SCRIPT_DIR/swiftbar-plugin/agent-inbox.5s.sh"
  ln -sf "$SCRIPT_DIR/swiftbar-plugin/agent-inbox.5s.sh" "$PLUGIN_DIR/agent-inbox.5s.sh"
  open -a SwiftBar
  echo "Menubar inbox installed (SwiftBar plugin: $PLUGIN_DIR/agent-inbox.5s.sh)"
else
  echo "Tip: brew install --cask swiftbar, then re-run for the sticky menubar inbox."
fi
