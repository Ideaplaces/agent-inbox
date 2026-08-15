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
#   ~/.agent-inbox/config       (optional: POLL_SECONDS, NOTIFY_SOUND, EXPIRE_MINUTES)

CONF_DIR="$HOME/.agent-inbox"
POLL_SECONDS=15
NOTIFY_SOUND=""     # silent by default; set to a macOS sound name (Glass, Ping, ...) to hear one
EXPIRE_MINUTES=5    # drop inbox items after this much time AT THE KEYBOARD (0 = never)
IDLE_THRESHOLD=90   # seconds without input before we consider you away
[ -f "$CONF_DIR/config" ] && . "$CONF_DIR/config"

GUILD="$(cat "$CONF_DIR/guild-id" 2>/dev/null || true)"
TN=/opt/homebrew/bin/terminal-notifier
TOKEN="$(cat "$CONF_DIR/bot-token" 2>/dev/null)"
CHANNEL="$(cat "$CONF_DIR/channel-id" 2>/dev/null)"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
if [ -z "${NTFY_TOPIC:-}" ] && [ -s "$CONF_DIR/ntfy-topic" ]; then
  NTFY_TOPIC="$(cat "$CONF_DIR/ntfy-topic")"
fi

if [ -n "$TOKEN" ] && [ -n "$CHANNEL" ]; then
  MODE=discord
  # Deep link needs the guild; without it fall back to the web client.
  if [ -n "$GUILD" ]; then
    OPEN_URL="discord://-/channels/$GUILD/$CHANNEL"
  else
    OPEN_URL="https://discord.com/channels/@me/$CHANNEL"
  fi
elif [ -n "${NTFY_TOPIC:-}" ]; then
  MODE=ntfy
  OPEN_URL="$NTFY_SERVER/$NTFY_TOPIC"
else
  echo "watcher not configured: run install-mac-watcher.sh <name> (Discord) or install-mac-watcher.sh --ntfy <topic>" >&2
  exit 1
fi

notify() { # $1 title, $2 body
  local title body
  title="$(printf '%s' "$1" | tr -d '"\\' | head -c 120)"
  body="$(printf '%s' "$2" | tr '\n' ' ' | tr -d '"\\' | head -c 240)"
  if [ -x "$TN" ]; then
    # Click jumps to the transport's history (Discord app or ntfy web).
    # Omitting -sound keeps it silent; NOTIFY_SOUND opts back in.
    if [ -n "$NOTIFY_SOUND" ]; then
      "$TN" -title "$title" -message "${body:-...}" -sound "$NOTIFY_SOUND" \
        -open "$OPEN_URL" >/dev/null 2>&1 && return 0
    else
      "$TN" -title "$title" -message "${body:-...}" \
        -open "$OPEN_URL" >/dev/null 2>&1 && return 0
    fi
  fi
  if [ -n "$NOTIFY_SOUND" ]; then
    osascript -e "display notification \"$body\" with title \"$title\" sound name \"$NOTIFY_SOUND\"" >/dev/null 2>&1
  else
    osascript -e "display notification \"$body\" with title \"$title\"" >/dev/null 2>&1
  fi
}

# Seconds you have actually spent at this Mac, accumulated by the poll loop.
# Inbox items expire against THIS clock, not wall time: while you work they
# age out as noise, while you are away they wait for you.
presence() { cat "$CONF_DIR/presence" 2>/dev/null || echo 0; }

presence_tick() {
  local idle now
  idle="$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')"
  [ -n "$idle" ] || idle=0
  if [ "$idle" -lt "$IDLE_THRESHOLD" ]; then
    now=$(( $(presence) + POLL_SECONDS ))
    printf '%s' "$now" > "$CONF_DIR/presence"
  fi
}

# unread.log columns: HH:MM \t presence-at-arrival \t host \t cwd \t title \t body
inbox_append() { # $1 title, $2 body, $3 host, $4 cwd
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%H:%M')" "$(presence)" \
    "${3:-}" "${4:-}" \
    "$(printf '%s' "$1" | tr '\t\n' '  ')" \
    "$(printf '%s' "$2" | tr '\t\n' '  ' | head -c 160)" >> "$CONF_DIR/unread.log"
}

inbox_expire() {
  [ "${EXPIRE_MINUTES:-0}" -gt 0 ] || return 0
  [ -s "$CONF_DIR/unread.log" ] || return 0
  local cutoff tmp
  cutoff=$(( $(presence) - EXPIRE_MINUTES * 60 ))
  [ "$cutoff" -gt 0 ] || return 0
  tmp="$(mktemp)"
  # Keep rows younger than the cutoff. Legacy rows (no presence column) are
  # dropped once they are older than the window.
  awk -F'\t' -v c="$cutoff" 'NF>=6 ? ($2+0) > c : 0' "$CONF_DIR/unread.log" > "$tmp" \
    && mv "$tmp" "$CONF_DIR/unread.log" || rm -f "$tmp"
}

fetch() { # $1 query string
  curl -m 10 -s -H "Authorization: Bot $TOKEN" \
    "https://discord.com/api/v10/channels/$CHANNEL/messages?$1"
}

# Titles read "<emoji> <repo> @ <host>[ (duration)]"; footers end with the cwd
# after " · ". Both let the menubar open the session in VS Code.
host_of()   { printf '%s' "$1" | sed -n 's/.* @ \([^ (]*\).*/\1/p'; }
cwd_of()    { printf '%s' "$1" | sed -n 's/.*· \(\/.*\)$/\1/p'; }

if [ "$MODE" = "discord" ]; then
  # First run: set the cursor to the newest message without replaying history.
  if [ ! -f "$CONF_DIR/last-id" ]; then
    fetch "limit=1" | jq -r '.[0].id // empty' > "$CONF_DIR/last-id"
    echo "watcher started (discord), cursor initialized"
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
          FOOT="$(printf '%s' "$MSG" | jq -r '.embeds[0].footer.text // ""')"
          notify "$TITLE" "$BODY"
          inbox_append "$TITLE" "$BODY" "$(host_of "$TITLE")" "$(cwd_of "$FOOT")"
        done
        printf '%s' "$BATCH" | jq -r '.[0].id' > "$CONF_DIR/last-id"
      fi
    fi
    presence_tick
    inbox_expire
    sleep "$POLL_SECONDS"
  done
else
  # ntfy mode: poll the topic's JSON feed with a since-cursor (epoch first run,
  # then last message id so nothing is replayed or missed).
  CURSOR_FILE="$CONF_DIR/ntfy-cursor"
  if [ ! -s "$CURSOR_FILE" ]; then
    date +%s > "$CURSOR_FILE"
    echo "watcher started (ntfy), cursor initialized"
  fi
  while true; do
    SINCE="$(cat "$CURSOR_FILE")"
    BATCH="$(curl -m 15 -s "$NTFY_SERVER/$NTFY_TOPIC/json?poll=1&since=$SINCE" \
      | jq -cs '[.[] | select(.event=="message")]' 2>/dev/null)"
    if printf '%s' "$BATCH" | jq -e 'type=="array" and length > 0' >/dev/null 2>&1; then
      printf '%s' "$BATCH" | jq -c '.[]' | while IFS= read -r MSG; do
        TITLE="$(printf '%s' "$MSG" | jq -r '.title // "Agent Inbox"')"
        # First body line only — the footer line stays in the ntfy history.
        BODY="$(printf '%s' "$MSG" | jq -r '.message // "" | split("\n") | .[0]')"
        FOOT="$(printf '%s' "$MSG" | jq -r '.message // "" | split("\n") | last')"
        notify "$TITLE" "$BODY"
        inbox_append "$TITLE" "$BODY" "$(host_of "$TITLE")" "$(cwd_of "$FOOT")"
      done
      printf '%s' "$BATCH" | jq -r 'last.id' > "$CURSOR_FILE"
    fi
    presence_tick
    inbox_expire
    sleep "$POLL_SECONDS"
  done
fi
