#!/usr/bin/env bash
# agent-inbox: Claude Code hook -> Discord #agent-inbox
#
# Called by Claude Code hooks with the event kind as $1 (prompt|stop|notification).
# Reads the hook JSON payload on stdin. Never blocks or fails the session:
# every exit path is 0 and the Discord post has a short timeout.
#
# Install: ./install.sh  (writes hooks into ~/.claude/settings.json and caches
# the webhook URL from Azure Key Vault into ~/.agent-inbox/webhook-url)

KIND="$1"
CONF_DIR="$HOME/.agent-inbox"
STATE_DIR="$CONF_DIR/state"
mkdir -p "$STATE_DIR" 2>/dev/null

# Config (optional): MIN_SECONDS, HOST_LABEL
MIN_SECONDS=45
HOST_LABEL="$(hostname -s)"
[ -f "$CONF_DIR/config" ] && . "$CONF_DIR/config"

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')"
REPO="$(basename "${CWD:-unknown}")"
NOW="$(date +%s)"

case "$KIND" in
  prompt)
    # Record when the user handed work to the agent; used to skip quick turns.
    [ -n "$SESSION_ID" ] && printf '%s' "$NOW" > "$STATE_DIR/$SESSION_ID.start"
    exit 0
    ;;

  stop)
    START=0
    [ -n "$SESSION_ID" ] && [ -f "$STATE_DIR/$SESSION_ID.start" ] && START="$(cat "$STATE_DIR/$SESSION_ID.start")"
    if [ "$START" -gt 0 ]; then
      ELAPSED=$(( NOW - START ))
      # Quick conversational turns don't belong in the inbox.
      [ "$ELAPSED" -lt "$MIN_SECONDS" ] && exit 0
      DURATION="$(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"
    else
      DURATION="unknown"
    fi
    SNIPPET=""
    if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
      SNIPPET="$(tail -n 200 "$TRANSCRIPT" | jq -rs '[.[] | select(.type=="assistant")] | last | .message.content | map(select(.type=="text") | .text) | join("\n")' 2>/dev/null | head -c 700)"
    fi
    if [ "$DURATION" = "unknown" ]; then
      TITLE="✅ $REPO @ $HOST_LABEL"
    else
      TITLE="✅ $REPO @ $HOST_LABEL ($DURATION)"
    fi
    COLOR=5763719
    BODY="$SNIPPET"
    FOOTER="session ${SESSION_ID:0:8} · $CWD"
    ;;

  notification)
    MESSAGE="$(printf '%s' "$INPUT" | jq -r '.message // "Waiting for input"')"
    TITLE="🖐️ $REPO @ $HOST_LABEL"
    COLOR=16705372
    BODY="$MESSAGE"
    FOOTER="session ${SESSION_ID:0:8} · $CWD"
    ;;

  *)
    exit 0
    ;;
esac

WEBHOOK_FILE="$CONF_DIR/webhook-url"
[ -f "$WEBHOOK_FILE" ] || exit 0
WEBHOOK="$(cat "$WEBHOOK_FILE")"
[ -n "$WEBHOOK" ] || exit 0

PAYLOAD="$(jq -n \
  --arg title "$TITLE" \
  --arg body "$BODY" \
  --arg footer "$FOOTER" \
  --argjson color "$COLOR" \
  '{embeds: [{title: $title, description: $body, color: $color, footer: {text: $footer}}]}')"

curl -m 5 -s -o /dev/null -H "Content-Type: application/json" -d "$PAYLOAD" "$WEBHOOK" || true
exit 0
