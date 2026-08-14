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

# Last non-empty assistant text in the transcript. fromjson? tolerates the
# line tail may have truncated and skips tool-call-only entries.
last_assistant_text() { # $1 max chars
  [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || return 0
  tail -n 300 "$TRANSCRIPT" | jq -Rrs '[split("\n")[] | fromjson? | select(.type=="assistant") | .message.content | if type=="array" then ([.[] | select(.type=="text") | .text] | join("\n")) else tostring end | select(length>0)] | last // ""' 2>/dev/null | head -c "$1"
}

# Extract real user-message texts from transcript lines on stdin, skipping
# system wrappers (<local-command-caveat>, <command-name>) and tool-result
# entries that also arrive with type=="user". $1 = "first" or "last".
_user_text() {
  jq -Rrs '[split("\n")[] | fromjson? | select(.type=="user") | .message.content | if type=="array" then ([.[]? | objects | select(.type=="text") | .text] | join(" ")) else tostring end | gsub("^\\s+";"") | select(length>0) | select(startswith("<") | not)] | '"$1"' // ""' 2>/dev/null \
    | tr '\n' ' ' | sed 's/[⎿⧉].*//' | head -c 150
}

# What this chat means, as up to two lines:
#   🧵 Claude Code's own conversation summary (what this session has been about)
#   🗣 the most recent real user message (what you asked for right now)
# Long sessions drift far from their first prompt, so recency beats origin;
# the first prompt is only the last-resort fallback.
session_context() {
  [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || return 0
  local sum ask out=""
  sum="$(grep -m 20 '"type":"summary"' "$TRANSCRIPT" 2>/dev/null | tail -1 | jq -r '.summary // ""' 2>/dev/null | tr '\n' ' ' | head -c 150)"
  ask="$(tail -n 500 "$TRANSCRIPT" | _user_text last)"
  if [ -z "$sum" ] && [ -z "$ask" ]; then
    ask="$(head -n 100 "$TRANSCRIPT" | _user_text first)"
  fi
  [ -n "$sum" ] && out="🧵 $sum"
  if [ -n "$ask" ]; then
    [ -n "$out" ] && out="$out
"
    out="${out}🗣 $ask"
  fi
  printf '%s' "$out"
}

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
    SNIPPET="$(last_assistant_text 600)"
    CONTEXT="$(session_context)"
    [ -n "$CONTEXT" ] && SNIPPET="$CONTEXT
$SNIPPET"
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
    # Lead with what the chat is about, then what Claude is waiting on.
    CONTEXT="$(session_context)"
    LAST="$(last_assistant_text 400)"
    BODY=""
    [ -n "$CONTEXT" ] && BODY="$CONTEXT
"
    BODY="$BODY$MESSAGE"
    [ -n "$LAST" ] && BODY="$BODY
❯ $LAST"
    FOOTER="session ${SESSION_ID:0:8} · $CWD"
    ;;

  *)
    exit 0
    ;;
esac

# --- Transports: whichever is configured gets the event (both is fine) ---

# Discord (webhook): rich embed, channel history doubles as a browsable inbox.
if [ -s "$CONF_DIR/webhook-url" ]; then
  WEBHOOK="$(cat "$CONF_DIR/webhook-url")"
  PAYLOAD="$(jq -n \
    --arg title "$TITLE" \
    --arg body "$BODY" \
    --arg footer "$FOOTER" \
    --argjson color "$COLOR" \
    '{embeds: [{title: $title, description: $body, color: $color, footer: {text: $footer}}]}')"
  curl -m 5 -s -o /dev/null -H "Content-Type: application/json" -d "$PAYLOAD" "$WEBHOOK" || true
fi

# ntfy (https://ntfy.sh): zero-setup pub/sub — the topic name IS the channel.
# Configure via NTFY_TOPIC in ~/.agent-inbox/config or ~/.agent-inbox/ntfy-topic.
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
if [ -z "${NTFY_TOPIC:-}" ] && [ -s "$CONF_DIR/ntfy-topic" ]; then
  NTFY_TOPIC="$(cat "$CONF_DIR/ntfy-topic")"
fi
if [ -n "${NTFY_TOPIC:-}" ]; then
  PRIO="default"; [ "$KIND" = "notification" ] && PRIO="high"
  curl -m 5 -s -o /dev/null \
    -H "Title: $TITLE" -H "Priority: $PRIO" \
    -d "$BODY
$FOOTER" "$NTFY_SERVER/$NTFY_TOPIC" || true
fi
exit 0
