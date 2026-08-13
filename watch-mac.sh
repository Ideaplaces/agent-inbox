#!/usr/bin/env bash
# agent-inbox Mac watcher: polls the developer's #agent-inbox-<name> Discord
# channel and surfaces every new message on the Mac:
#   - native macOS notification (click opens the Discord channel)
#   - appends to ~/.agent-inbox/unread.log, the sticky inbox rendered in the
#     menubar by swiftbar-plugin/agent-inbox.5s.sh until marked read
#
# Runs as a launchd agent (see install-mac-watcher.sh). Reads:
#   ~/.agent-inbox/bot-token    (cached by install-mac-watcher.sh)
#   ~/.agent-inbox/channel-id   (cached by install-mac-watcher.sh)
#   ~/.agent-inbox/last-id      (cursor, managed here)
#   ~/.agent-inbox/config       (optional: POLL_SECONDS)

CONF_DIR="$HOME/.agent-inbox"
POLL_SECONDS=15
[ -f "$CONF_DIR/config" ] && . "$CONF_DIR/config"

GUILD=1462642831184232584
TN=/opt/homebrew/bin/terminal-notifier
TOKEN="$(cat "$CONF_DIR/bot-token" 2>/dev/null)"
CHANNEL="$(cat "$CONF_DIR/channel-id" 2>/dev/null)"
if [ -z "$TOKEN" ] || [ -z "$CHANNEL" ]; then
  echo "watcher not configured: run install-mac-watcher.sh <name>" >&2
  exit 1
fi

notify() { # $1 title, $2 body
  local title body
  title="$(printf '%s' "$1" | tr -d '"\\' | head -c 120)"
  body="$(printf '%s' "$2" | tr '\n' ' ' | tr -d '"\\' | head -c 240)"
  if [ -x "$TN" ]; then
    # Click jumps to the channel in the Discord app (history/context).
    "$TN" -title "$title" -message "${body:-...}" -sound Glass \
      -open "discord://-/channels/$GUILD/$CHANNEL" >/dev/null 2>&1 && return 0
  fi
  osascript -e "display notification \"$body\" with title \"$title\" sound name \"Glass\"" >/dev/null 2>&1
}

inbox_append() { # $1 title, $2 body — sticky menubar inbox entry
  printf '%s\t%s\t%s\n' "$(date '+%H:%M')" \
    "$(printf '%s' "$1" | tr '\t\n' '  ')" \
    "$(printf '%s' "$2" | tr '\t\n' '  ' | head -c 160)" >> "$CONF_DIR/unread.log"
}

fetch() { # $1 query string
  curl -m 10 -s -H "Authorization: Bot $TOKEN" \
    "https://discord.com/api/v10/channels/$CHANNEL/messages?$1"
}

# First run: set the cursor to the newest message without replaying history.
if [ ! -f "$CONF_DIR/last-id" ]; then
  fetch "limit=1" | jq -r '.[0].id // empty' > "$CONF_DIR/last-id"
  echo "watcher started, cursor initialized"
fi

while true; do
  LAST="$(cat "$CONF_DIR/last-id" 2>/dev/null)"
  if [ -z "$LAST" ]; then
    fetch "limit=1" | jq -r '.[0].id // empty' > "$CONF_DIR/last-id"
  else
    BATCH="$(fetch "after=$LAST&limit=20")"
    if printf '%s' "$BATCH" | jq -e 'type=="array" and length > 0' >/dev/null 2>&1; then
      # API returns newest first; deliver oldest first.
      printf '%s' "$BATCH" | jq -c 'reverse | .[]' | while IFS= read -r MSG; do
        TITLE="$(printf '%s' "$MSG" | jq -r '.embeds[0].title // .content // "Agent Inbox"')"
        # Description only — session id and path stay in the Discord history.
        BODY="$(printf '%s' "$MSG" | jq -r '.embeds[0].description // ""')"
        notify "$TITLE" "$BODY"
        inbox_append "$TITLE" "$BODY"
      done
      printf '%s' "$BATCH" | jq -r '.[0].id' > "$CONF_DIR/last-id"
    fi
  fi
  sleep "$POLL_SECONDS"
done
