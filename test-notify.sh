#!/usr/bin/env bash
# Tests for the sender's per-conversation tagging.
#
# Runs notify.sh against a throwaway HOME with AGENT_INBOX_DRY_RUN set, so it
# prints what it would send instead of posting. Nothing here touches a real
# transport, a real transcript, or your own ~/.agent-inbox.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="$HERE/notify.sh"
PASS=0

fail() { echo "FAIL $1"; echo "     $2"; exit 1; }
ok()   { PASS=$((PASS + 1)); echo "PASS $1"; }

new_home() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX"
  mkdir -p "$HOME/.agent-inbox"
}

# $1 = kind, $2 = json payload, rest of env carries WATCH_MODE
run() {
  printf '%s' "$2" | AGENT_INBOX_DRY_RUN=1 bash "$NOTIFY" "$1" 2>/dev/null
}

SID="test-session"
prompt_payload() { printf '{"session_id":"%s","cwd":"/tmp/repo","prompt":%s}' "$SID" "$(printf '%s' "$1" | jq -Rs .)"; }
notif_payload()  { printf '{"session_id":"%s","cwd":"/tmp/repo","message":"needs you"}' "$SID"; }

# --- default mode: everything reports ---
new_home
out="$(run notification "$(notif_payload)")"
case "$out" in *"WOULD SEND"*) ok "untagged session reports in the default mode";;
  *) fail "untagged session reports in the default mode" "got: $out";; esac

# --- #mute silences it ---
run prompt "$(prompt_payload 'carry on but #mute this one')" >/dev/null
out="$(run notification "$(notif_payload)")"
[ -z "$out" ] && ok "#mute silences the conversation" \
  || fail "#mute silences the conversation" "got: $out"

# --- and a later tag turns it back on: last tag wins ---
run prompt "$(prompt_payload 'actually #notify me again')" >/dev/null
out="$(run notification "$(notif_payload)")"
case "$out" in *"WOULD SEND"*) ok "a later tag wins over an earlier one";;
  *) fail "a later tag wins over an earlier one" "got: $out";; esac

# --- every alias works ---
for tag in '#notify' '#inbox' '#watch' '#agent-inbox'; do
  new_home
  export WATCH_MODE=tagged
  printf 'WATCH_MODE=tagged\n' > "$HOME/.agent-inbox/config"
  out="$(run notification "$(notif_payload)")"
  [ -n "$out" ] && fail "tagged mode is silent until tagged" "got: $out"
  run prompt "$(prompt_payload "please $tag this")" >/dev/null
  out="$(run notification "$(notif_payload)")"
  case "$out" in *"WOULD SEND"*) ok "tagged mode: $tag enables the conversation";;
    *) fail "tagged mode: $tag enables the conversation" "got: $out";; esac
done
unset WATCH_MODE

# --- tagged mode stays silent with no tag at all ---
new_home
printf 'WATCH_MODE=tagged\n' > "$HOME/.agent-inbox/config"
run prompt "$(prompt_payload 'just a normal message')" >/dev/null
out="$(run notification "$(notif_payload)")"
[ -z "$out" ] && ok "tagged mode ignores an untagged conversation" \
  || fail "tagged mode ignores an untagged conversation" "got: $out"

# --- #mute beats an on-tag in the same message, so "#notify ... #mute" is off ---
new_home
run prompt "$(prompt_payload 'was #notify, now #mute')" >/dev/null
out="$(run notification "$(notif_payload)")"
[ -z "$out" ] && ok "#mute takes precedence within one message" \
  || fail "#mute takes precedence within one message" "got: $out"

# --- one conversation's tag must not affect another ---
new_home
run prompt "$(prompt_payload '#mute')" >/dev/null
SID="other-session"
out="$(run notification "$(notif_payload)")"
case "$out" in *"WOULD SEND"*) ok "muting one conversation leaves others alone";;
  *) fail "muting one conversation leaves others alone" "got: $out";; esac
SID="test-session"

# --- a payload with no prompt field must not blow up or write state ---
new_home
printf '{"session_id":"%s","cwd":"/tmp/repo"}' "$SID" \
  | AGENT_INBOX_DRY_RUN=1 bash "$NOTIFY" prompt >/dev/null 2>&1
[ ! -f "$HOME/.agent-inbox/state/$SID.watch" ] \
  && ok "a prompt with no text records no decision" \
  || fail "a prompt with no text records no decision" "state file was written"

# --- the tags themselves are configurable ---
new_home
cat > "$HOME/.agent-inbox/config" <<'CFG'
WATCH_MODE=tagged
WATCH_TAGS="#ping @@follow"
MUTE_TAG="#quiet"
CFG
out="$(run notification "$(notif_payload)")"
[ -z "$out" ] && ok "a custom list ignores the built-in tags" \
  || fail "a custom list ignores the built-in tags" "got: $out"

run prompt "$(prompt_payload 'the old #notify should do nothing now')" >/dev/null
out="$(run notification "$(notif_payload)")"
[ -z "$out" ] && ok "a replaced tag stops working" \
  || fail "a replaced tag stops working" "got: $out"

run prompt "$(prompt_payload 'try @@follow instead')" >/dev/null
out="$(run notification "$(notif_payload)")"
case "$out" in *"WOULD SEND"*) ok "a custom watch tag enables the conversation";;
  *) fail "a custom watch tag enables the conversation" "got: $out";; esac

run prompt "$(prompt_payload 'now #quiet please')" >/dev/null
out="$(run notification "$(notif_payload)")"
[ -z "$out" ] && ok "a custom mute tag silences the conversation" \
  || fail "a custom mute tag silences the conversation" "got: $out"

# --- case does not matter ---
new_home
printf 'WATCH_MODE=tagged\n' > "$HOME/.agent-inbox/config"
run prompt "$(prompt_payload 'shouting #NOTIFY at it')" >/dev/null
out="$(run notification "$(notif_payload)")"
case "$out" in *"WOULD SEND"*) ok "tags match regardless of case";;
  *) fail "tags match regardless of case" "got: $out";; esac

# --- an empty list must not become an inescapable silence ---
new_home
cat > "$HOME/.agent-inbox/config" <<'CFG'
WATCH_MODE=tagged
WATCH_TAGS=""
CFG
run prompt "$(prompt_payload 'falling back, so #notify still works')" >/dev/null
out="$(run notification "$(notif_payload)")"
case "$out" in *"WOULD SEND"*) ok "an empty tag list falls back to the defaults";;
  *) fail "an empty tag list falls back to the defaults" "got: $out";; esac

# --- an empty mute tag must not silence everything ---
new_home
cat > "$HOME/.agent-inbox/config" <<'CFG'
MUTE_TAG=""
CFG
run prompt "$(prompt_payload 'a message with no tags at all')" >/dev/null
out="$(run notification "$(notif_payload)")"
case "$out" in *"WOULD SEND"*) ok "an empty mute tag does not silence everything";;
  *) fail "an empty mute tag does not silence everything" "got: $out";; esac

echo
echo "$PASS checks passed"
