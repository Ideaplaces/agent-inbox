#!/usr/bin/env bash
# agent-inbox sender: Claude Code hook -> an ntfy topic.
#
# Called by Claude Code hooks with the event kind as $1 (prompt|stop|notification).
# Reads the hook JSON payload on stdin. Never blocks or fails the session:
# every exit path is 0 and each post has a short timeout.
#
# Install with ./install.sh --ntfy <topic>, which also writes the hooks into
# ~/.claude/settings.json.
#
# HOST_LABEL (see ~/.agent-inbox/config) is the machine name shown in every
# message. On a remote machine set it to that machine's SSH host alias, so the
# Mac menubar can open the session over Remote-SSH.

KIND="$1"
CONF_DIR="$HOME/.agent-inbox"
STATE_DIR="$CONF_DIR/state"
mkdir -p "$STATE_DIR" 2>/dev/null

# Config (optional): MIN_SECONDS, HOST_LABEL
MIN_SECONDS=45
HOST_LABEL="$(hostname -s)"
# all    every session reports, and the mute tag silences one
# tagged nothing reports until a watch tag turns it on
WATCH_MODE=all
# The tags themselves, so they can be changed without touching this script.
# Space separated, or comma separated when a tag is a phrase with spaces in it,
# which is what dictation needs: "hashtag notify" does not become "#notify",
# but "watch this one" is easy to say. Matching ignores case.
WATCH_TAGS="#notify, #inbox, #watch, #agent-inbox, watch this, notify me"
MUTE_TAG="#mute, stop notifying"
[ -f "$CONF_DIR/config" ] && . "$CONF_DIR/config"

# The exact title a control event carries. A real event's title is
# "<symbol> <repo> @ <host>", so nothing legitimate can collide with it.
CONTROL_TITLE="agent-inbox:control"

# ntfy settings, read on demand so both the normal send and send_control get
# them without either depending on the other having run first.
_load_ntfy_config() {
  NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
  if [ -z "${NTFY_TOPIC:-}" ] && [ -s "$CONF_DIR/ntfy-topic" ]; then
    NTFY_TOPIC="$(cat "$CONF_DIR/ntfy-topic")"
  fi
  # Kept out of `config`, which the app writes world-readable, because it is a
  # credential.
  if [ -z "${NTFY_TOKEN:-}" ] && [ -s "$CONF_DIR/ntfy-token" ]; then
    NTFY_TOKEN="$(cat "$CONF_DIR/ntfy-token")"
  fi
}

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')"
REPO="$(basename "${CWD:-unknown}")"
NOW="$(date +%s)"

# --- Per-conversation opt in and out ---
#
# Typing #notify (or #inbox, #watch, #agent-inbox) in a conversation makes it
# report; #mute silences it. The most recent tag wins, so a session can be
# flipped as often as you like.
#
# There is nothing to scan. The UserPromptSubmit hook is handed the prompt
# text, so the tag is read straight off what you typed and the answer is
# remembered per session. A transcript can be tens of megabytes; it is never
# opened for this.
#
# Deliberately a plain substring match. A tag inside pasted code counts, and
# that is fine: nobody is harmed by a conversation they did not mean to watch,
# and the alternative is parsing that gets clever and then gets it wrong.
WATCH_FILE="$STATE_DIR/${SESSION_ID}.watch"

# An empty watch list in tagged mode would be a silence nothing could escape,
# so fall back to the defaults rather than leaving the inbox permanently dead.
[ -n "${WATCH_TAGS// /}" ] || WATCH_TAGS="#notify, #inbox, #watch, #agent-inbox, watch this, notify me"

# One tag per line. Commas win when present, so a tag can contain spaces;
# otherwise whitespace separates, which keeps the "#a #b" form working.
split_tags() {
  local raw="$1" sep=' '
  case "$raw" in *,*) sep=',' ;; esac
  printf '%s' "$raw" | tr "$sep" '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

record_tags() { # $1 = the text the user just submitted
  local text tag
  [ -n "$SESSION_ID" ] || return 0
  # Matching ignores case: a tag that works only in lower case looks broken
  # rather than strict.
  text="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    case "$text" in
      *"$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')"*)
        printf 'off' > "$WATCH_FILE"; return 0 ;;
    esac
  done <<EOF
$(split_tags "$MUTE_TAG")
EOF

  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    case "$text" in
      *"$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')"*)
        printf 'on' > "$WATCH_FILE"; return 0 ;;
    esac
  done <<EOF
$(split_tags "$WATCH_TAGS")
EOF
}

# Should this session report? Sessions with no tag follow WATCH_MODE.
should_report() {
  local state=""
  [ -n "$SESSION_ID" ] && [ -f "$WATCH_FILE" ] && state="$(cat "$WATCH_FILE")"
  case "$state" in
    on)  return 0 ;;
    off) return 1 ;;
  esac
  [ "$WATCH_MODE" = "tagged" ] && return 1
  return 0
}

# Last non-empty assistant text in the transcript. fromjson? tolerates the
# line tail may have truncated and skips tool-call-only entries.
last_assistant_text() { # $1 max chars
  [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || return 0
  tail -n 300 "$TRANSCRIPT" | jq -Rrs '[split("\n")[] | fromjson? | select(.type=="assistant") | .message.content | if type=="array" then ([.[] | select(.type=="text") | .text] | join("\n")) else tostring end | select(length>0)] | last // ""' 2>/dev/null | head -c "$1"
}

# The agent's closing words: the first sentence of its last message and the
# last one, joined by an ellipsis.
#
# A row that names the repo and the subject is not enough to recognise a
# conversation you left two days and several hundred thousand tokens ago, and
# the head of the last message is the wrong 600 characters: it truncates
# mid-word, long before the part that says how the turn ended. The two
# sentences that carry the most are the one that opens the answer and the one
# that closes it.
#
# Prose only. Fenced code, tables, rules and list markers are dropped, since a
# closing line of `};` identifies nothing. Line ends count as sentence ends,
# because an agent writes in short lines, headings and bullets that often carry
# no full stop at all.
closing_words() { # $1 = max chars per sentence, default 160
  last_assistant_text 8000 | awk -v max="${1:-160}" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

    # A full stop that ends one of these ends a word, not a sentence.
    function is_abbrev(w) {
      return (w ~ /^([A-Za-z]|[Ee]\.g|[Ii]\.e|vs|etc|approx|no|No|Mr|Mrs|Ms|Dr|Inc|Ltd|Fig|al)$/)
    }

    # Cutting anywhere can leave an opening ** or ` with no partner, which the
    # menu would draw as a literal marker. Drop an unpaired one.
    function balance(s,   n) {
      n = gsub(/\*\*/, "&", s); if (n % 2) gsub(/\*\*/, "", s)
      n = gsub(/`/, "&", s);     if (n % 2) gsub(/`/, "", s)
      return s
    }

    # Cut at a word boundary, so the ellipsis reads as elision and not damage.
    function clip(s,   cut) {
      if (length(s) <= max) return balance(s)
      cut = substr(s, 1, max)
      if (match(cut, /^.*[ ]/)) cut = substr(cut, 1, RLENGTH - 1)
      return balance(trim(cut)) "…"
    }

    # A fragment under 25 characters is held and joined to the sentence that
    # follows it, rather than standing as one: an opening sentence of "Done."
    # says nothing the checkmark had not already said, and a heading is a
    # fragment of the paragraph under it.
    function keep(s) {
      s = trim(s)
      if (s == "") return
      if (held != "") s = held " " s
      if (length(s) < 25) { held = s; return }
      S[++N] = s; held = ""
    }

    function sentences(text,   i, len, ch, nxt, cur, word) {
      cur = ""; len = length(text)
      for (i = 1; i <= len; i++) {
        ch = substr(text, i, 1)
        cur = cur ch
        if (ch != "." && ch != "!" && ch != "?") continue
        nxt = substr(text, i + 1, 1)
        if (nxt != "" && nxt != " ") continue
        word = cur; sub(/[.!?]+$/, "", word); sub(/^.*[ ]/, "", word)
        if (is_abbrev(word)) continue
        keep(cur); cur = ""
      }
      keep(cur)
    }

    BEGIN { fence = 0; N = 0; held = "" }
    /^[ \t]*(```|~~~)/ { fence = 1 - fence; next }
    fence { next }
    {
      line = trim($0)
      sub(/^[>#]+[ \t]*/, "", line)               # quotes and headings
      sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", line)  # list markers
      line = trim(line)
      if (line == "") next
      if (line ~ /^[|]/) next                     # table rows
      if (line ~ /^([-*_=][ \t]*)+$/) next        # rules
      sentences(line)
    }

    END {
      if (held != "") { if (N > 0) S[N] = S[N] " " held; else S[++N] = held }
      if (N == 0) exit
      if (N == 1) { print clip(S[1]); exit }
      print clip(S[1]) " … " clip(S[N])
    }
  '
}

# Extract real user-message texts from transcript lines on stdin, skipping
# system wrappers (<local-command-caveat>, <command-name>) and tool-result
# entries that also arrive with type=="user". $1 = "first" or "last".
# An attached screenshot lands in the transcript as a long cache path, which
# would otherwise fill the whole line the reader actually needs.
_user_text() {
  jq -Rrs '[split("\n")[] | fromjson? | select(.type=="user") | .message.content | if type=="array" then ([.[]? | objects | select(.type=="text") | .text] | join(" ")) else tostring end | gsub("^\\s+";"") | select(length>0) | select(startswith("<") | not)] | '"$1"' // ""' 2>/dev/null \
    | tr '\n' ' ' | sed 's/[⎿⧉].*//' \
    | sed 's/\[Image: source:[^]]*\]//g; s/\[Image #[0-9]*\]//g' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 150
}

# Did the agent stop by asking something?
#
# The Notification hook fires for two unrelated things and the payload does not
# tell them apart: a permission request, which really is blocked on you, and a
# plain idle timer that trips 60 seconds after a turn ends whether or not
# anything was asked. Every needsYou item on this machine was the second kind,
# arriving 60s after the stop event and repeating it under a hand.
#
# For the idle case the only honest signal is the agent's own last line. Read
# it untruncated, since the 400-char body cut would hide the question mark.
agent_asked_a_question() {
  local last
  last="$(last_assistant_text 8000 \
    | sed 's/[[:space:]]*$//' | grep -v '^[[:space:]]*$' | tail -1)"
  case "$last" in
    *\?) return 0 ;;
    *) return 1 ;;
  esac
}

# Tell the inbox to do something, rather than showing up in it.
#
# Control events ride the same topic as everything else and are told apart by an
# exact title: a real event's title always carries a repo and an @host, so the
# two can never be confused.
send_control() { # $1 = the instruction
  _load_ntfy_config
  [ -n "${NTFY_TOPIC:-}" ] || return 0
  local auth=()
  [ -n "${NTFY_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl -m 5 -s -o /dev/null \
    "${auth[@]+"${auth[@]}"}" \
    -H "Title: $CONTROL_TITLE" -H "Priority: min" \
    -d "$1" "$NTFY_SERVER/$NTFY_TOPIC" || true
}

# What this chat means, as up to two lines:
#   🧵 what this session is about
#   🗣 the most recent real user message (what you asked for right now)
# Long sessions drift far from their first prompt, so recency beats origin;
# the first prompt is only the last-resort fallback.
#
# Sets SUMMARY and ASK, the two values, and CONTEXT, the rendered lines. They
# are variables rather than output because the same two values also go into
# the contract line below, and a value computed once cannot disagree with
# itself.
session_context() {
  SUMMARY=""; ASK=""; CONTEXT=""
  [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || return 0
  local sum ask out=""
  # Trimmed like _user_text is: jq ends its output with a newline, which tr
  # turns into a trailing space that the contract line would otherwise carry.
  sum="$(grep -m 20 '"type":"summary"' "$TRANSCRIPT" 2>/dev/null | tail -1 | jq -r '.summary // ""' 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' | head -c 150)"
  # A summary entry is only written when a session is compacted, and most never
  # are: across every transcript on this machine the count was zero, so the
  # thread line has never once been sent and every notification arrived as a
  # last message with no subject. Claude Code also writes an `ai-title` entry,
  # which exists from the first turn, so fall back to that. Bounded read: the
  # entry repeats often and a transcript can be tens of megabytes.
  if [ -z "$sum" ]; then
    sum="$(tail -n 2000 "$TRANSCRIPT" 2>/dev/null | grep '"type":"ai-title"' | tail -1 \
      | jq -r '.aiTitle // ""' 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' | head -c 150)"
  fi
  # Neither entry exists on older Claude Code: the Linux boxes run 2.1.12,
  # which writes no summary and no ai-title, so both lookups above come back
  # empty there and the subject line would still never appear. The message the
  # session opened with is a fair statement of what it is about, and every
  # transcript on every version has one.
  [ -z "$sum" ] && sum="$(head -n 200 "$TRANSCRIPT" | _user_text first)"
  ask="$(tail -n 500 "$TRANSCRIPT" | _user_text last)"
  # A session still on its first message would otherwise print it twice.
  [ "$sum" = "$ask" ] && sum=""
  [ -n "$sum" ] && out="🧵 $sum"
  if [ -n "$ask" ]; then
    [ -n "$out" ] && out="$out
"
    out="${out}🗣 $ask"
  fi
  SUMMARY="$sum"; ASK="$ask"; CONTEXT="$out"
}

# The same message again, as one line of JSON after the human lines and the
# footer.
#
# Everything above it is convention: the app takes the title apart on " @ "
# and a trailing "(...)", sorts the body lines by the emoji they start with and
# finds the footer by its "session xxxxxxxx" shape. Bash assembles, Swift
# disassembles, and nothing but habit keeps the two in step: a body with its
# subject line missing parsed fine for a whole release. This line is the
# contract. Every field named, absent ones null, and a version so the app can
# tell what it is reading. The human lines stay for the ntfy History page and
# for older apps.
#
# jq builds it. Hand-concatenated JSON is one quote in an agent's sentence away
# from a line the app cannot parse, and the closing words are exactly the kind
# of text that carries quotes, backslashes and newlines. Every string goes in
# through --arg, so jq does the escaping.
contract_line() { # $1 = finished | needsYou
  jq -nc \
    --arg kind "$1" --arg repo "$REPO" --arg host "$HOST_LABEL" \
    --arg duration "${DURATION:-}" --argjson elapsed "${ELAPSED:-null}" \
    --arg summary "${SUMMARY:-}" --arg ask "${ASK:-}" --arg closing "${CLOSING:-}" \
    --arg detail "${DETAIL:-}" --arg waitingOn "${WAITING_ON:-}" \
    --arg session "${SESSION_ID:0:8}" --arg cwd "$CWD" \
    'def nul: if . == "" then null else . end;
     {v: 1, kind: $kind, repo: $repo, host: $host,
      duration: ($duration | nul), elapsed: $elapsed,
      summary: ($summary | nul), ask: ($ask | nul), closing: ($closing | nul),
      detail: ($detail | nul), waitingOn: ($waitingOn | nul),
      session: ($session | nul), cwd: ($cwd | nul)}' 2>/dev/null
}

case "$KIND" in
  prompt)
    # Record when the user handed work to the agent; used to skip quick turns.
    [ -n "$SESSION_ID" ] && printf '%s' "$NOW" > "$STATE_DIR/$SESSION_ID.start"
    record_tags "$(printf '%s' "$INPUT" | jq -r '.prompt // empty')"
    # Nothing else ever removes a session's .start or .watch, so the directory
    # only grows: 47 files on one Mac, 218 on a dev box. A prompt is the cheap
    # place to sweep, once per message you type. A week is long past any
    # session anyone comes back to, and a swept .watch simply means the
    # conversation follows WATCH_MODE again. Silent, and never a reason for the
    # hook to fail.
    find "$STATE_DIR" -type f -mtime +7 -delete 2>/dev/null || true
    # Typing in a conversation is proof you have seen it, so its row in the
    # inbox is answered and should go. Only sent when this session actually has
    # something outstanding: without the marker every prompt would publish a
    # clear for a session the inbox has never heard of.
    if [ -n "$SESSION_ID" ] && [ -f "$STATE_DIR/$SESSION_ID.notified" ]; then
      # The same eight characters the footer carries, because that is all the
      # app ever sees: it reads the session id out of "session ${SESSION_ID:0:8}"
      # and stores the truncation. Sending the full id here would be an
      # instruction to clear a session the inbox has never heard of, and it
      # would fail silently, which is the worst way for this to be wrong.
      send_control "clear ${SESSION_ID:0:8}"
      rm -f "$STATE_DIR/$SESSION_ID.notified"
    fi
    exit 0
    ;;

  stop)
    START=0
    [ -n "$SESSION_ID" ] && [ -f "$STATE_DIR/$SESSION_ID.start" ] && START="$(cat "$STATE_DIR/$SESSION_ID.start")"
    # Both stay empty when the start time is unknown. The title reads that as
    # "no duration" and the contract line as null.
    ELAPSED=""; DURATION=""
    if [ "$START" -gt 0 ]; then
      ELAPSED=$(( NOW - START ))
      # Quick conversational turns don't belong in the inbox.
      [ "$ELAPSED" -lt "$MIN_SECONDS" ] && exit 0
      DURATION="$(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"
    fi
    # How the turn ended, which is what tells two long sessions apart. Falls
    # back to the head of the last message when there is no prose to reduce,
    # so a turn that ended in a code block still says something.
    CLOSING="$(closing_words)"
    DETAIL=""
    [ -z "$CLOSING" ] && DETAIL="$(last_assistant_text 600)"
    WAITING_ON=""
    session_context
    if [ -n "$DURATION" ]; then
      TITLE="✅ $REPO @ $HOST_LABEL ($DURATION)"
    else
      TITLE="✅ $REPO @ $HOST_LABEL"
    fi
    BODY=""
    [ -n "$CONTEXT" ] && BODY="$CONTEXT
"
    # Braced, because bash takes the emoji's bytes as part of the name and
    # "$BODY💬" silently expands to nothing, dropping the context above it.
    [ -n "$CLOSING" ] && BODY="${BODY}💬 $CLOSING"
    [ -n "$DETAIL" ] && BODY="${BODY}$DETAIL"
    FOOTER="session ${SESSION_ID:0:8} · $CWD"
    CONTRACT="$(contract_line finished)"
    ;;

  notification)
    MESSAGE="$(printf '%s' "$INPUT" | jq -r '.message // "Waiting for input"')"
    # The hand has to mean "this one is blocked on you", or it means nothing.
    # Gate only the idle message: anything else this hook reports, a permission
    # request above all, is a real block and keeps the hand.
    case "$MESSAGE" in
      *"waiting for your input"*|*"Waiting for input"*)
        agent_asked_a_question || exit 0
        ;;
    esac
    TITLE="🖐️ $REPO @ $HOST_LABEL"
    # Lead with what the chat is about, then what Claude is waiting on.
    session_context
    # The same first-and-last reduction the ✅ carries. The head of the message
    # was the wrong end to show here: an agent that stops on a question puts it
    # in the final line, past where 400 characters cut.
    WAITING_ON="$(closing_words)"
    [ -z "$WAITING_ON" ] && WAITING_ON="$(last_assistant_text 400)"
    DETAIL="$MESSAGE"
    ELAPSED=""; DURATION=""; CLOSING=""
    BODY=""
    [ -n "$CONTEXT" ] && BODY="$CONTEXT
"
    BODY="$BODY$DETAIL"
    [ -n "$WAITING_ON" ] && BODY="$BODY
❯ $WAITING_ON"
    FOOTER="session ${SESSION_ID:0:8} · $CWD"
    CONTRACT="$(contract_line needsYou)"
    ;;

  *)
    exit 0
    ;;
esac

# A muted conversation, or an untagged one in tagged mode, stops here. The turn
# timer and the tag state are already recorded, so muting and unmuting mid
# conversation works without leaving anything stale behind.
should_report || exit 0

# What goes on the wire: the human lines, the footer, then the contract line
# last. The order is part of the contract, the app looks for the JSON on the
# final line. Should jq have produced nothing, the message still goes out as
# it always has, and the app falls back to reading the lines above.
WIRE="$BODY
$FOOTER"
[ -n "${CONTRACT:-}" ] && WIRE="$WIRE
$CONTRACT"

# AGENT_INBOX_DRY_RUN prints what would be sent instead of sending it, which is
# what makes the sender testable without a live transport.
if [ -n "${AGENT_INBOX_DRY_RUN:-}" ]; then
  printf 'WOULD SEND\ntitle: %s\nbody: %s\n' "$TITLE" "$WIRE"
  exit 0
fi

# --- Transport ---

# ntfy (https://ntfy.sh): zero-setup pub/sub — the topic name IS the channel.
# Configure via NTFY_TOPIC in ~/.agent-inbox/config or ~/.agent-inbox/ntfy-topic.
_load_ntfy_config
# A self-hosted server can require auth, and ours does: it runs deny-all so a
# leaked topic name is not access. Public ntfy.sh needs none, so the header is
# added only when a token exists and the sender keeps working either way.
#
# Kept in its own file rather than in `config`, because config is world-readable
# by design (the app rewrites it) and this is a credential.
if [ -n "${NTFY_TOPIC:-}" ]; then
  PRIO="default"; [ "$KIND" = "notification" ] && PRIO="high"
  NTFY_AUTH=()
  [ -n "${NTFY_TOKEN:-}" ] && NTFY_AUTH=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl -m 5 -s -o /dev/null \
    "${NTFY_AUTH[@]+"${NTFY_AUTH[@]}"}" \
    -H "Title: $TITLE" -H "Priority: $PRIO" \
    -d "$WIRE" "$NTFY_SERVER/$NTFY_TOPIC" || true
fi

# Remember that this session now has a row waiting, so the next prompt knows
# there is something to clear. Written last, after the transports, so a session
# that reported into nothing does not later publish a clear for a row that was
# never created.
[ -n "$SESSION_ID" ] && : > "$STATE_DIR/$SESSION_ID.notified"
exit 0
