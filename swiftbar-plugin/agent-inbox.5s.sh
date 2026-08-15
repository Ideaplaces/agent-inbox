#!/usr/bin/env bash
# agent-inbox SwiftBar plugin: sticky menubar inbox.
# Shows a badge of unread agent events (🖐️ needs-you / ✅ finished). Clicking
# an item opens that session's VS Code window (local or Remote-SSH).
#
# Items are written by watch-mac.sh into ~/.agent-inbox/unread.log and expire
# there after EXPIRE_MINUTES of you actually being at the keyboard, so the list
# stays short while you work but survives while you are away.
#
# SwiftBar runs this every 5s (filename convention). Also callable as:
#   agent-inbox.5s.sh clear

CONF_DIR="$HOME/.agent-inbox"
UNREAD="$CONF_DIR/unread.log"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"
# The plugin is symlinked into SwiftBar's plugin dir; resolve back to the repo.
REPO="$(dirname "$(readlink "$SELF" 2>/dev/null || echo "$SELF")")/.."
OPENER="$(cd "$REPO" 2>/dev/null && pwd)/open-session.sh"
GUILD="$(cat "$CONF_DIR/guild-id" 2>/dev/null)"
CHANNEL="$(cat "$CONF_DIR/channel-id" 2>/dev/null)"

if [ "${1:-}" = "clear" ]; then
  if [ -f "$UNREAD" ]; then
    cat "$UNREAD" >> "$CONF_DIR/read-archive.log" 2>/dev/null
    rm -f "$UNREAD"
  fi
  exit 0
fi

NEEDS=0; DONE=0
if [ -s "$UNREAD" ]; then
  NEEDS=$(grep -c '🖐' "$UNREAD" 2>/dev/null || true)
  DONE=$(grep -c '✅' "$UNREAD" 2>/dev/null || true)
fi

# Menubar title: quiet when empty, and lead with what needs you.
if [ "${NEEDS:-0}" -eq 0 ] && [ "${DONE:-0}" -eq 0 ]; then
  echo "🤖"
else
  T=""
  [ "$NEEDS" -gt 0 ] && T="🖐️$NEEDS"
  [ "$DONE" -gt 0 ] && T="$T ✅$DONE"
  echo "$T"
fi

echo "---"
if [ -s "$UNREAD" ]; then
  # Newest first. Click opens the session in VS Code; the body hangs off the
  # submenu so the row itself stays scannable.
  # Normalize pre-1.1 rows (time/title/body) to the current 6-column shape, and
  # re-join with US (0x1f): `read` collapses empty tab-separated fields.
  awk -F'\t' 'BEGIN{OFS=sprintf("%c",31)}
       NF>=6 {print $1,$2,$3,$4,$5,$6}
       NF==3 {print $1,0,"","",$2,$3}' "$UNREAD" \
    | tail -r | head -25 | while IFS=$'\037' read -r TS PRES HOST CWD TITLE BODY; do
    if [ -n "$CWD" ] && [ -x "$OPENER" ]; then
      echo "$TS  $TITLE | length=70 trim=true bash=$OPENER param1=$HOST param2=$CWD terminal=false"
    else
      echo "$TS  $TITLE | length=70 trim=true"
    fi
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
