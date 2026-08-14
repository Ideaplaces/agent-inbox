#!/usr/bin/env bash
# agent-inbox SwiftBar plugin: sticky menubar inbox.
# Shows a badge of unread agent events (🖐️ needs-you / ✅ finished) that stays
# until "Mark all read". The watcher (watch-mac.sh) appends entries to
# ~/.agent-inbox/unread.log; this plugin renders and clears them.
#
# SwiftBar runs this every 5s (filename convention). Also callable with an
# action argument:   agent-inbox.5s.sh clear

CONF_DIR="$HOME/.agent-inbox"
UNREAD="$CONF_DIR/unread.log"
GUILD="$(cat "$CONF_DIR/guild-id" 2>/dev/null)"
CHANNEL="$(cat "$CONF_DIR/channel-id" 2>/dev/null)"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

if [ "${1:-}" = "clear" ]; then
  if [ -f "$UNREAD" ]; then
    cat "$UNREAD" >> "$CONF_DIR/read-archive.log" 2>/dev/null
    rm -f "$UNREAD"
  fi
  exit 0
fi

NEEDS=0; DONE=0; OTHER=0
if [ -f "$UNREAD" ]; then
  NEEDS=$(grep -c '🖐' "$UNREAD" 2>/dev/null || true)
  DONE=$(grep -c '✅' "$UNREAD" 2>/dev/null || true)
  TOTAL=$(grep -c '' "$UNREAD" 2>/dev/null || true)
  OTHER=$(( TOTAL - NEEDS - DONE ))
fi

# Menubar title: quiet when inbox is empty, loud when agents wait on you.
if [ "${NEEDS:-0}" -eq 0 ] && [ "${DONE:-0}" -eq 0 ] && [ "${OTHER:-0}" -eq 0 ]; then
  echo "🤖"
else
  T=""
  [ "$NEEDS" -gt 0 ] && T="🖐️$NEEDS"
  [ "$DONE" -gt 0 ] && T="$T ✅$DONE"
  [ "$OTHER" -gt 0 ] && T="$T ●$OTHER"
  echo "$T"
fi

echo "---"
if [ -s "$UNREAD" ]; then
  # Newest first, 🖐️ items are what you act on — show all, trimmed.
  tail -r "$UNREAD" 2>/dev/null | head -25 | while IFS=$'\t' read -r TS TITLE BODY; do
    echo "$TS  $TITLE | length=70 trim=true"
    [ -n "$BODY" ] && echo "--$BODY | length=90 trim=true"
  done
  echo "---"
  echo "Mark all read | bash=$SELF param1=clear terminal=false refresh=true"
else
  echo "Inbox zero — no agents waiting"
fi
if [ -n "$CHANNEL" ]; then
  if [ -n "$GUILD" ]; then
    echo "Open channel in Discord | href=discord://-/channels/$GUILD/$CHANNEL"
  else
    echo "Open channel in Discord | href=https://discord.com/channels/@me/$CHANNEL"
  fi
fi
if [ -s "$CONF_DIR/ntfy-topic" ]; then
  echo "Open ntfy history | href=${NTFY_SERVER:-https://ntfy.sh}/$(cat "$CONF_DIR/ntfy-topic")"
fi
