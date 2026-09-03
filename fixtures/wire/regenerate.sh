#!/usr/bin/env bash
# Regenerates fixtures/wire/*.txt: what notify.sh puts on the wire, byte for
# byte, for a set of hand-made transcripts.
#
# The bash sender and the Swift parser had only ever been checked against
# each other by a person reading both. These files are the sender's side of
# that check, committed: test-notify.sh regenerates them into a temp dir and
# fails if they drift, and the Mac app's WireFixtureTests decodes every one of
# them the way the receiver does. A change to either side now has to agree
# with the other before it lands.
#
# Each file is the dry run's output with its "WOULD SEND" line removed: the
# `title:` line, then `body:` and the rest of the body, footer and contract
# line included. Everything that could vary is pinned: HOST_LABEL through the
# sandbox config, the session id, the cwd, and the clock through
# AGENT_INBOX_NOW with each .start file computed from it.
#
# Usage: fixtures/wire/regenerate.sh [output-dir]   (default: this directory)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="$HERE/../../notify.sh"
OUT="${1:-$HERE}"
mkdir -p "$OUT"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"
mkdir -p "$HOME/.agent-inbox/state"
printf 'HOST_LABEL=devbox\nMIN_SECONDS=0\n' > "$HOME/.agent-inbox/config"

SID="a1b2c3d4-0000-4000-8000-000000000000"
CWD="/home/me/my-app"
NOW=1700000000
TRANSCRIPT="$SANDBOX/transcript.jsonl"
export AGENT_INBOX_NOW="$NOW" AGENT_INBOX_DRY_RUN=1

# The transcript is built with jq so quotes and backslashes in the agent's
# words are escaped by a program, not by hand.
title() { jq -nc --arg t "$1" '{type:"ai-title", aiTitle:$t}'; }
user()  { jq -nc --arg t "$1" '{type:"user", message:{content:[{type:"text", text:$t}]}}'; }
agent() { jq -nc --arg t "$1" '{type:"assistant", message:{content:[{type:"text", text:$t}]}}'; }

started_ago() { printf '%s' "$(( NOW - $1 ))" > "$HOME/.agent-inbox/state/$SID.start"; }
never_started() { rm -f "$HOME/.agent-inbox/state/$SID.start"; }

emit() { # $1 = scenario name, $2 = stop | notification, $3 = the hook's message
  local payload out
  payload="$(jq -nc --arg s "$SID" --arg c "$CWD" --arg t "$TRANSCRIPT" --arg m "${3:-}" \
    '{session_id:$s, cwd:$c, transcript_path:$t} + (if $m == "" then {} else {message:$m} end)')"
  out="$(printf '%s' "$payload" | bash "$NOTIFY" "$2")"
  case "$out" in
    "WOULD SEND"$'\n'"title: "*) ;;
    *) echo "regenerate: $1 produced no message" >&2; exit 1 ;;
  esac
  printf '%s\n' "$out" | tail -n +2 > "$OUT/$1.txt"
}

# A finished turn with everything filled in: subject, ask, closing, duration.
{ title "Rework the refund ledger"; user "and the chargeback path"
  agent "Chargebacks post to the ledger and the backfill finished cleanly. The first pass timed out on the orders table, so it took two. Ship it when you are ready."
} > "$TRANSCRIPT"
started_ago 252
emit finished-basic stop

# Three seconds: the row the app offers to hide.
{ title "Say hello"; user "hello"
  agent "Hello! Ready when you are, what should we work on today?"
} > "$TRANSCRIPT"
started_ago 3
emit finished-short stop

# No .start file, so duration and elapsed are null. No ai-title either, so the
# subject falls back to the first prompt, which is also the last, so it is
# carried once, as the ask.
{ user "Why is the enum duplicated across three files?"
  agent "The enum is generated into each package by the schema step, so the three copies are one source. I removed the two stale hand edits and regenerated."
} > "$TRANSCRIPT"
never_started
emit finished-no-start stop

# The last message is a fenced block and nothing else: no prose to reduce, so
# closing is null and detail carries the raw message.
{ title "Push the branch"; user "push it"
  agent "$(printf '```\ngit push origin main\n```')"
} > "$TRANSCRIPT"
started_ago 40
emit finished-code-only stop

# The closing words carry a double quote, a backslash, " · /" and an emoji.
# " · /" is what makes Transport.splitFooter peel the contract line into the
# footer slot instead of the human footer, so this fixture exercises the
# second of the parser's two arrangements.
{ title "Fix the path"; user "fix the path"
  agent "$(printf 'Renamed "old" to C:\\tmp\\new · /srv/app and it built 🚀. Nothing else is outstanding here.')"
} > "$TRANSCRIPT"
started_ago 61
emit finished-tricky-text stop

# A permission request is a real block whatever the last line looks like.
{ title "Run the migration"; user "run it against staging"
  agent "Staging is reachable and the migration plan is three steps. Running the first step now."
} > "$TRANSCRIPT"
emit needsyou-permission notification "Claude needs your permission to use Bash"

# The idle timer only raises a hand when the agent's last line is a question.
{ title "Pick a car"; user "look at the listing"
  agent "Same car, same seller, and the price dropped again since last week. Which of those three should I keep?"
} > "$TRANSCRIPT"
emit needsyou-question notification "Claude is waiting for your input"
