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

# What this chat is about: prefer Claude Code's own generated session summary
# (the title shown in `claude --resume`), fall back to the first user prompt.
session_task() { # $1 max chars
  [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || return 0
  local s
  s="$(grep -m 5 '"type":"summary"' "$TRANSCRIPT" 2>/dev/null | tail -1 | jq -r '.summary // ""' 2>/dev/null)"
  if [ -z "$s" ]; then
    # First real user prompt; skip system wrappers (<local-command-caveat>,
    # <command-name>, tool results) that also arrive as user entries.
    s="$(head -n 100 "$TRANSCRIPT" | jq -Rrs '[split("\n")[] | fromjson? | select(.type=="user") | .message.content | if type=="array" then ([.[]? | objects | select(.type=="text") | .text] | join(" ")) else tostring end | gsub("^\\s+";"") | select(length>0) | select(startswith("<") | not)] | first // ""' 2>/dev/null)"
  fi
  # Strip terminal-paste artifacts (tool-result markers, selection markers).
  printf '%s' "$s" | tr '\n' ' ' | sed 's/[⎿⧉].*//' | head -c "$1"
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
    TASK="$(session_task 150)"
    [ -n "$TASK" ] && SNIPPET="🧵 $TASK
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
    TASK="$(session_task 150)"
    LAST="$(last_assistant_text 400)"
    BODY=""
    [ -n "$TASK" ] && BODY="🧵 $TASK
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
