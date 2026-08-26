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

# --- spoken phrases, which is what dictation can actually produce ---
new_home
cat > "$HOME/.agent-inbox/config" <<'CFG'
WATCH_MODE=tagged
WATCH_TAGS="watch this, notify me"
MUTE_TAG="stop notifying"
CFG
run prompt "$(prompt_payload 'ok please watch this one for me')" >/dev/null
out="$(run notification "$(notif_payload)")"
case "$out" in *"WOULD SEND"*) ok "a spoken phrase enables the conversation";;
  *) fail "a spoken phrase enables the conversation" "got: $out";; esac

run prompt "$(prompt_payload 'you can stop notifying me about it')" >/dev/null
out="$(run notification "$(notif_payload)")"
[ -z "$out" ] && ok "a spoken phrase silences the conversation" \
  || fail "a spoken phrase silences the conversation" "got: $out"

# The bug phrases were built to fix: a phrase must not match on one loose word.
new_home
cat > "$HOME/.agent-inbox/config" <<'CFG'
WATCH_MODE=tagged
WATCH_TAGS="watch this, notify me"
CFG
run prompt "$(prompt_payload 'lets do this')" >/dev/null
out="$(run notification "$(notif_payload)")"
[ -z "$out" ] && ok "a phrase does not match on a single loose word" \
  || fail "a phrase does not match on a single loose word" "got: $out"

run prompt "$(prompt_payload 'can you watch the build')" >/dev/null
out="$(run notification "$(notif_payload)")"
[ -z "$out" ] && ok "a phrase needs the whole phrase, not its first word" \
  || fail "a phrase needs the whole phrase, not its first word" "got: $out"

# --- the space separated form still works, so nobody's config breaks ---
new_home
cat > "$HOME/.agent-inbox/config" <<'CFG'
WATCH_MODE=tagged
WATCH_TAGS="#alpha #beta"
CFG
run prompt "$(prompt_payload 'using #beta here')" >/dev/null
out="$(run notification "$(notif_payload)")"
case "$out" in *"WOULD SEND"*) ok "the space separated form still works";;
  *) fail "the space separated form still works" "got: $out";; esac

# --- the shipped defaults must work when dictated ---
new_home
printf 'WATCH_MODE=tagged\n' > "$HOME/.agent-inbox/config"
run prompt "$(prompt_payload 'watch this one please')" >/dev/null
out="$(run notification "$(notif_payload)")"
case "$out" in *"WOULD SEND"*) ok "a dictated phrase works with no config at all";;
  *) fail "a dictated phrase works with no config at all" "got: $out";; esac

run prompt "$(prompt_payload 'you can stop notifying now')" >/dev/null
out="$(run notification "$(notif_payload)")"
[ -z "$out" ] && ok "the dictated mute phrase works with no config at all" \
  || fail "the dictated mute phrase works with no config at all" "got: $out"

# The typed forms must survive alongside the spoken ones.
new_home
printf 'WATCH_MODE=tagged\n' > "$HOME/.agent-inbox/config"
run prompt "$(prompt_payload 'typed #inbox still counts')" >/dev/null
out="$(run notification "$(notif_payload)")"
case "$out" in *"WOULD SEND"*) ok "typed tags still work alongside spoken ones";;
  *) fail "typed tags still work alongside spoken ones" "got: $out";; esac

run prompt "$(prompt_payload 'and #mute still counts')" >/dev/null
out="$(run notification "$(notif_payload)")"
[ -z "$out" ] && ok "the typed mute tag still works alongside the spoken one" \
  || fail "the typed mute tag still works alongside the spoken one" "got: $out"

# --- an attached screenshot must not fill the line ---
UT="$(mktemp)"; sed -n '/^# An attached screenshot/,/^}/p' "$HERE/notify.sh" > "$UT"
img='{"type":"user","message":{"content":[{"type":"text","text":"[Image: source: /Users/x/.claude/image-cache/abc/9.png] Do you know why nothing appears?"}]}}'
got="$(printf '%s\n' "$img" | bash -c "source $UT; _user_text last")"
[ "$got" = "Do you know why nothing appears?" ] \
  && ok "an image cache path is stripped from the snippet" \
  || fail "an image cache path is stripped from the snippet" "got: [$got]"

plainmsg='{"type":"user","message":{"content":[{"type":"text","text":"just a normal message"}]}}'
got="$(printf '%s\n' "$plainmsg" | bash -c "source $UT; _user_text last")"
[ "$got" = "just a normal message" ] \
  && ok "ordinary text is left alone" \
  || fail "ordinary text is left alone" "got: [$got]"
rm -f "$UT"

# --- the thread line must survive a transcript that was never compacted ---
#
# The bug this pins: `"type":"summary"` is only written when a session is
# compacted, and most sessions never are, so every notification went out with
# a last message and no subject. `ai-title` is present from the first turn.
CT="$(mktemp)"
sed -n '/^# An attached screenshot/,/^}/p' "$HERE/notify.sh" > "$CT"
sed -n '/^session_context()/,/^}/p' "$HERE/notify.sh" >> "$CT"

TR="$(mktemp)"
cat > "$TR" <<'TRANSCRIPT'
{"type":"ai-title","aiTitle":"Menubar padding and the CI runner"}
{"type":"user","message":{"content":[{"type":"text","text":"I think we don't get sounds."}]}}
TRANSCRIPT
got="$(TRANSCRIPT="$TR" bash -c "source $CT; TRANSCRIPT=$TR session_context")"
case "$got" in
  *"Menubar padding and the CI runner"*) ok "an uncompacted session still gets a subject line";;
  *) fail "an uncompacted session still gets a subject line" "got: [$got]";;
esac
case "$got" in
  *"I think we don't get sounds."*) ok "the last message is still carried alongside it";;
  *) fail "the last message is still carried alongside it" "got: [$got]";;
esac

# A real summary, once one exists, still wins over the title.
cat > "$TR" <<'TRANSCRIPT'
{"type":"ai-title","aiTitle":"a stale title"}
{"type":"summary","summary":"the compacted summary"}
{"type":"user","message":{"content":[{"type":"text","text":"carry on"}]}}
TRANSCRIPT
got="$(TRANSCRIPT="$TR" bash -c "source $CT; TRANSCRIPT=$TR session_context")"
case "$got" in
  *"the compacted summary"*) ok "a real summary still beats the title";;
  *) fail "a real summary still beats the title" "got: [$got]";;
esac
# --- older Claude Code writes neither entry, and still needs a subject ---
#
# The Linux dev boxes run 2.1.12, whose transcripts contain no summary and no
# ai-title. Without a third fallback the subject line stays empty exactly where
# most sessions run.
TR2="$(mktemp)"
cat > "$TR2" <<'TRANSCRIPT'
{"type":"user","message":{"content":[{"type":"text","text":"Why is the enum duplicated across three files?"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"working on it"}]}}
{"type":"user","message":{"content":[{"type":"text","text":"run the full gate"}]}}
TRANSCRIPT
got="$(bash -c "source $CT; TRANSCRIPT=$TR2 session_context")"
case "$got" in
  *"Why is the enum duplicated"*) ok "a transcript with no title still gets a subject";;
  *) fail "a transcript with no title still gets a subject" "got: [$got]";;
esac
case "$got" in
  *"run the full gate"*) ok "and still carries the latest message";;
  *) fail "and still carries the latest message" "got: [$got]";;
esac

# One prompt in, origin and latest are the same line; print it once.
cat > "$TR2" <<'TRANSCRIPT'
{"type":"user","message":{"content":[{"type":"text","text":"only one message so far"}]}}
TRANSCRIPT
got="$(bash -c "source $CT; TRANSCRIPT=$TR2 session_context")"
count="$(printf '%s' "$got" | grep -c "only one message so far")"
[ "$count" = "1" ] \
  && ok "a one-message session does not repeat itself" \
  || fail "a one-message session does not repeat itself" "got: [$got]"
rm -f "$TR2"

# --- the hand must mean blocked, not idle ---
#
# Claude Code fires the Notification hook 60 seconds after a turn ends whether
# or not anything was asked. Every needsYou item on this machine was that idle
# timer: 13 of 13 arrived 60-80s after a finished item and repeated it under a
# hand, so the marker carried no information at all.
TR3="$(mktemp)"
mk_transcript() { # $1 = the agent's closing line
  cat > "$TR3" <<TRANSCRIPT
{"type":"user","message":{"content":[{"type":"text","text":"look at the listing"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"$1"}]}}
TRANSCRIPT
}
notif_with() { printf '{"session_id":"q1","cwd":"/tmp/repo","transcript_path":"%s","message":"%s"}' "$TR3" "$2"; }

new_home
mk_transcript "Same car, same seller. It is a relist, not a new car."
out="$(run notification "$(notif_with x 'Claude is waiting for your input')")"
[ -z "$out" ] && ok "an idle timer with no question raises no hand" \
  || fail "an idle timer with no question raises no hand" "got: $out"

mk_transcript "Which of those three should I keep?"
out="$(run notification "$(notif_with x 'Claude is waiting for your input')")"
case "$out" in *"WOULD SEND"*) ok "an idle timer after a real question still raises one";;
  *) fail "an idle timer after a real question still raises one" "got: $out";; esac

# A permission prompt is a real block whatever the last line looks like.
mk_transcript "Running the migration now."
out="$(run notification "$(notif_with x 'Claude needs your permission to use Bash')")"
case "$out" in *"WOULD SEND"*) ok "a permission request always raises a hand";;
  *) fail "a permission request always raises a hand" "got: $out";; esac

# The question mark sits past the body truncation, so it must be read untruncated.
long="$(printf 'a%.0s' $(seq 1 500))"
mk_transcript "$long Should I go ahead?"
out="$(run notification "$(notif_with x 'Claude is waiting for your input')")"
case "$out" in *"WOULD SEND"*) ok "a question past the body cut is still seen";;
  *) fail "a question past the body cut is still seen" "got: $out";; esac
rm -f "$TR3"

# --- ntfy auth: the token is sent when there is one, and only then ---
#
# Our own server runs deny-all, so an unauthenticated publish is a 403 and the
# session reports into nothing. Public ntfy.sh takes no token at all, so the
# header has to be conditional rather than always present. Dry-run exits before
# the transports, so this stubs curl and reads back what would have been sent.
stub_curl_home() {
  new_home
  STUB="$HOME/bin"
  mkdir -p "$STUB"
  cat > "$STUB/curl" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$CURL_ARGS"
exit 0
STUBEOF
  chmod +x "$STUB/curl"
  export CURL_ARGS="$HOME/curl-args.txt"
  : > "$CURL_ARGS"
  printf 'agent-inbox' > "$HOME/.agent-inbox/ntfy-topic"
  printf 'NTFY_SERVER="https://ntfy.example.com:8443"\n' > "$HOME/.agent-inbox/config"
}

send_for_real() { printf '%s' "$2" | PATH="$STUB:$PATH" bash "$NOTIFY" "$1" >/dev/null 2>&1; }

stub_curl_home
printf 'tk_secrettoken' > "$HOME/.agent-inbox/ntfy-token"
send_for_real notification "$(notif_payload)"
if grep -q "Authorization: Bearer tk_secrettoken" "$CURL_ARGS"; then
  ok "a configured token is sent as a bearer header"
else
  fail "a configured token is sent as a bearer header" "args: $(tr '\n' ' ' < "$CURL_ARGS")"
fi
grep -q "https://ntfy.example.com:8443/agent-inbox" "$CURL_ARGS" \
  && ok "the configured server and topic are used" \
  || fail "the configured server and topic are used" "args: $(tr '\n' ' ' < "$CURL_ARGS")"

stub_curl_home
send_for_real notification "$(notif_payload)"
if grep -q "Authorization:" "$CURL_ARGS"; then
  fail "no token means no auth header, so ntfy.sh still works" "args: $(tr '\n' ' ' < "$CURL_ARGS")"
else
  ok "no token means no auth header, so ntfy.sh still works"
fi
grep -q "/agent-inbox" "$CURL_ARGS" \
  && ok "and the message is still published" \
  || fail "and the message is still published" "args: $(tr '\n' ' ' < "$CURL_ARGS")"

# --- typing in a conversation clears its row, but only if it has one ---
#
# The Notification hook fires on an idle timer, so a clear published on every
# prompt would tell the inbox to retire sessions it has never heard of. The
# marker is what makes it "clear the row you are showing" rather than noise.
stub_curl_home
send_for_real stop "$(printf '{"session_id":"%s","cwd":"/tmp/repo"}' "$SID")"
: > "$CURL_ARGS"
send_for_real prompt "$(prompt_payload 'carry on then')"
# The id must be the truncated one the footer carries, which is all the app
# ever stores. Sending the full id would clear nothing, silently.
if grep -q "agent-inbox:control" "$CURL_ARGS" && grep -qx "clear ${SID:0:8}" "$CURL_ARGS"; then
  ok "typing after a notification publishes a clear for that session"
else
  fail "typing after a notification publishes a clear for that session" \
    "args: $(tr '\n' ' ' < "$CURL_ARGS")"
fi

: > "$CURL_ARGS"
send_for_real prompt "$(prompt_payload 'and again')"
if grep -q "agent-inbox:control" "$CURL_ARGS"; then
  fail "a second prompt does not clear again" "args: $(tr '\n' ' ' < "$CURL_ARGS")"
else
  ok "a second prompt does not clear again, the row is already gone"
fi

stub_curl_home
send_for_real prompt "$(prompt_payload 'first thing I have said')"
if grep -q "agent-inbox:control" "$CURL_ARGS"; then
  fail "a session that never reported publishes no clear" "args: $(tr '\n' ' ' < "$CURL_ARGS")"
else
  ok "a session that never reported publishes no clear"
fi

# The control event is ntfy's business. Discord is a record of what happened,
# and "the user started typing" is not something to keep forever.
stub_curl_home
printf 'https://discord.example.com/webhook' > "$HOME/.agent-inbox/webhook-url"
send_for_real stop "$(printf '{"session_id":"%s","cwd":"/tmp/repo"}' "$SID")"
: > "$CURL_ARGS"
send_for_real prompt "$(prompt_payload 'go on')"
if grep -q "discord.example.com" "$CURL_ARGS"; then
  fail "the clear is not sent to Discord" "args: $(tr '\n' ' ' < "$CURL_ARGS")"
else
  ok "the clear goes to ntfy only, never to Discord"
fi

rm -f "$CT" "$TR"

echo
echo "$PASS checks passed"
