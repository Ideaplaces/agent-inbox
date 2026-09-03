#!/usr/bin/env bash
# Tests for the two shell installers, install.sh and install-remote.sh.
#
# Both run against a throwaway HOME. AGENT_INBOX_RAW_BASE points install-remote.sh
# at this checkout over file:// so nothing is fetched from GitHub, and
# AGENT_INBOX_DRY_RUN makes the test event each install sends at the end print
# instead of post. Nothing here touches your own ~/.claude/settings.json or
# ~/.agent-inbox.
#
# The Mac app writes the same hooks (mac/Sources/AgentInbox/Services/HookInstaller.swift)
# and has to recognise the shell's as installed, so the shape it expects is
# asserted here against what the shell wrote.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"   # captured output lives here, never in the sandbox HOME
PASS=0
export AGENT_INBOX_DRY_RUN=1
export AGENT_INBOX_RAW_BASE="file://$HERE"

fail() { echo "FAIL $1"; echo "     $2"; exit 1; }
ok()   { PASS=$((PASS + 1)); echo "PASS $1"; }

new_home() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX"
  SETTINGS="$HOME/.claude/settings.json"
  BACKUP="$SETTINGS.bak.agent-inbox"
  CONF="$HOME/.agent-inbox"
  REMOTE_NOTIFY="$CONF/bin/notify.sh"
}

# Run an installer, keep its exit code in RC and its streams in OUT and ERR.
run() {
  "$@" >"$WORK/out" 2>"$WORK/err"; RC=$?
  OUT="$(cat "$WORK/out")"; ERR="$(cat "$WORK/err")"
}
remote() { run bash "$HERE/install-remote.sh" "$@"; }
local_install() { run bash "$HERE/install.sh" "$@"; }

commands() { jq -r --arg ev "$1" '.hooks[$ev] // [] | .[] | .hooks // [] | .[] | .command' "$SETTINGS"; }
command_count() { commands UserPromptSubmit | wc -l; commands Stop | wc -l; commands Notification | wc -l; }

# Exactly one command per event, in the app's form: bash "<path>" <kind>.
expect_hooks() {  # $1 = path the hooks should run, $2 = label
  for pair in UserPromptSubmit:prompt Stop:stop Notification:notification; do
    ev="${pair%%:*}"; kind="${pair##*:}"
    want="bash \"$1\" $kind"; got="$(commands "$ev")"
    [ "$got" = "$want" ] && ok "$2: $ev runs exactly [$want]" \
      || fail "$2: $ev runs exactly [$want]" "got: $got"
  done
}

# What HookInstaller.swift requires before it reports the hooks as installed:
# hooks.<event> is an array of entries, each entry's hooks is an array of
# {type: "command", command: <string>}, and for each event exactly one command
# contains notify.sh and ends in " <kind>", spelled the way command(for:script:)
# spells it. The shell has to satisfy the same rules or the app shows a
# machine with working hooks as not set up.
app_shape_ok() {  # $1 = path
  jq -e --arg p "$1" '
    . as $root
    | [["UserPromptSubmit","prompt"],["Stop","stop"],["Notification","notification"]]
    | all(.[0] as $ev | .[1] as $kind
        | ($root.hooks[$ev] | type) == "array"
        and ($root.hooks[$ev] | all((.hooks | type) == "array"
              and (.hooks | all(.type == "command" and (.command | type) == "string"))))
        and ([$root.hooks[$ev][].hooks[].command
              | select(contains("notify.sh") and endswith(" " + $kind))]
             == ["bash \"" + $p + "\" " + $kind]))
  ' "$SETTINGS" >/dev/null 2>&1
}

# ===== install-remote.sh =====

# --- a fresh machine: no ~/.claude at all ---
new_home
remote --ntfy mytopic --host-label devbox
[ "$RC" = 0 ] && ok "remote: a fresh HOME installs cleanly" \
  || fail "remote: a fresh HOME installs cleanly" "exit $RC, stderr: $ERR"
jq -e . "$SETTINGS" >/dev/null 2>&1 && ok "remote: settings.json is valid JSON" \
  || fail "remote: settings.json is valid JSON" "got: $(cat "$SETTINGS" 2>&1)"
keys="$(jq -c '.hooks | keys' "$SETTINGS")"
[ "$keys" = '["Notification","Stop","UserPromptSubmit"]' ] \
  && ok "remote: exactly the three events are wired" \
  || fail "remote: exactly the three events are wired" "got: $keys"
expect_hooks "$REMOTE_NOTIFY" "remote"
app_shape_ok "$REMOTE_NOTIFY" && ok "remote: the app recognises the shape as installed" \
  || fail "remote: the app recognises the shape as installed" "got: $(jq -c .hooks "$SETTINGS")"
[ "$(cat "$CONF/ntfy-topic")" = "mytopic" ] && ok "remote: ntfy-topic holds the topic" \
  || fail "remote: ntfy-topic holds the topic" "got: $(cat "$CONF/ntfy-topic" 2>&1)"
grep -qx 'HOST_LABEL="devbox"' "$CONF/config" && ok "remote: config carries the host label" \
  || fail "remote: config carries the host label" "got: $(cat "$CONF/config" 2>&1)"
[ -x "$REMOTE_NOTIFY" ] && cmp -s "$REMOTE_NOTIFY" "$HERE/notify.sh" \
  && ok "remote: bin/notify.sh is executable and identical to the repo's" \
  || fail "remote: bin/notify.sh is executable and identical to the repo's" "$(ls -l "$REMOTE_NOTIFY" 2>&1)"
case "$OUT" in *"WOULD SEND"*"@ devbox"*) ok "remote: the test event goes through the installed sender with the new label";;
  *) fail "remote: the test event goes through the installed sender with the new label" "got: $OUT";; esac

# --- a fetch that fails must not leave hooks pointing at a missing script ---
new_home
AGENT_INBOX_RAW_BASE="file://$SANDBOX/nowhere" remote --ntfy mytopic
[ "$RC" != 0 ] && [ ! -e "$SETTINGS" ] \
  && ok "remote: a failed download stops before settings.json is touched" \
  || fail "remote: a failed download stops before settings.json is touched" "exit $RC, settings: $(cat "$SETTINGS" 2>&1)"

# --- everything unrelated in settings.json survives, and a backup comes first ---
new_home
mkdir -p "$HOME/.claude"
cat > "$SETTINGS" <<'JSON'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(git status)", "Read"], "deny": []},
  "hooks": {
    "PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "./autopush.sh"}]}]
  }
}
JSON
cp "$SETTINGS" "$SANDBOX/original.json"
remote --ntfy mytopic
cmp -s "$BACKUP" "$SANDBOX/original.json" && ok "remote: the backup is the file as it was" \
  || fail "remote: the backup is the file as it was" "got: $(cat "$BACKUP" 2>&1)"
before="$(jq -S . "$SANDBOX/original.json")"
after="$(jq -S 'del(.hooks.UserPromptSubmit, .hooks.Stop, .hooks.Notification)' "$SETTINGS")"
[ "$before" = "$after" ] && ok "remote: model, permissions and PostToolUse survive untouched" \
  || fail "remote: model, permissions and PostToolUse survive untouched" "after: $after"

# --- running it twice does not double the hooks ---
remote --ntfy mytopic
[ "$(command_count | tr -d ' \n')" = "111" ] && ok "remote: a second run leaves one command per event" \
  || fail "remote: a second run leaves one command per event" "got: $(jq -c .hooks "$SETTINGS")"

# --- somebody's own Stop hook is kept, ours is added beside it ---
new_home
mkdir -p "$HOME/.claude"
cat > "$SETTINGS" <<'JSON'
{"hooks": {"Stop": [
  {"hooks": [{"type": "command", "command": "say done"}]},
  {"hooks": [{"type": "command", "command": "afplay ding.aiff"},
             {"type": "command", "command": "bash \"/old/checkout/notify.sh\" stop"}]}
]}}
JSON
remote --ntfy mytopic
want="$(printf 'say done\nafplay ding.aiff\nbash "%s" stop' "$REMOTE_NOTIFY")"
[ "$(commands Stop)" = "$want" ] \
  && ok "remote: foreign Stop hooks stay, an older notify.sh hook is replaced by ours" \
  || fail "remote: foreign Stop hooks stay, an older notify.sh hook is replaced by ours" "got: $(commands Stop)"
app_shape_ok "$REMOTE_NOTIFY" && ok "remote: and the app still reads that as installed" \
  || fail "remote: and the app still reads that as installed" "got: $(jq -c .hooks "$SETTINGS")"

# --- a corrupt settings.json is refused, not overwritten ---
#
# The jq failure used to sit inside "jq ... && mv ...", which set -e ignores,
# so the installer announced success over a file it had not touched.
new_home
mkdir -p "$HOME/.claude"
printf '{ not json' > "$SETTINGS"
printf 'earlier backup' > "$BACKUP"
remote --ntfy mytopic
[ "$RC" != 0 ] && ok "remote: invalid JSON exits non-zero" \
  || fail "remote: invalid JSON exits non-zero" "exit 0, stdout: $OUT"
case "$ERR" in *"$SETTINGS"*"not valid JSON"*) ok "remote: and says which file and why";;
  *) fail "remote: and says which file and why" "stderr: $ERR";; esac
[ "$(cat "$SETTINGS")" = '{ not json' ] && ok "remote: the corrupt file is left as it was" \
  || fail "remote: the corrupt file is left as it was" "got: $(cat "$SETTINGS")"
[ "$(cat "$BACKUP")" = 'earlier backup' ] && [ ! -e "$CONF" ] \
  && ok "remote: nothing else was written, the earlier backup included" \
  || fail "remote: nothing else was written, the earlier backup included" "backup: $(cat "$BACKUP"), conf: $(ls -A "$CONF" 2>&1)"

# --- an empty settings.json is an empty object, as the app reads it ---
#
# jq turns empty input into no output, so the mv used to leave the file empty
# and the hooks were never written.
new_home
mkdir -p "$HOME/.claude"
: > "$SETTINGS"
remote --ntfy mytopic
[ "$RC" = 0 ] && [ "$(command_count | tr -d ' \n')" = "111" ] \
  && ok "remote: an empty settings.json gets the three hooks" \
  || fail "remote: an empty settings.json gets the three hooks" "exit $RC, file: $(cat "$SETTINGS")"

# --- no jq: say so and write nothing ---
new_home
NOJQ="$SANDBOX/bin"; mkdir -p "$NOJQ"
for t in dirname cat mkdir chmod curl; do ln -s "$(command -v "$t")" "$NOJQ/$t"; done
PATH="$NOJQ" run "$BASH" "$HERE/install-remote.sh" --ntfy mytopic
[ "$RC" != 0 ] && [ ! -e "$SETTINGS" ] && [ ! -e "$CONF" ] \
  && ok "remote: without jq it exits non-zero and writes nothing" \
  || fail "remote: without jq it exits non-zero and writes nothing" "exit $RC, home: $(ls -A "$HOME")"
case "$ERR" in *jq*) ok "remote: and names jq";; *) fail "remote: and names jq" "stderr: $ERR";; esac

# --- a topic is required ---
new_home
remote --ntfy
[ "$RC" != 0 ] && [ -z "$(ls -A "$HOME")" ] && ok "remote: --ntfy with no topic is a usage error that writes nothing" \
  || fail "remote: --ntfy with no topic is a usage error that writes nothing" "exit $RC, home: $(ls -A "$HOME")"
case "$ERR" in *usage:*) ok "remote: and prints usage";; *) fail "remote: and prints usage" "stderr: $ERR";; esac
remote
[ "$RC" != 0 ] && [ -z "$(ls -A "$HOME")" ] && ok "remote: no arguments is a usage error that writes nothing" \
  || fail "remote: no arguments is a usage error that writes nothing" "exit $RC, home: $(ls -A "$HOME")"

# --- the host label: set once, replaced in place, kept when not given ---
new_home
mkdir -p "$CONF"; printf 'MIN_SECONDS=45\n' > "$CONF/config"
remote --ntfy mytopic --host-label first
remote --ntfy mytopic --host-label second
[ "$(grep -c '^HOST_LABEL=' "$CONF/config")" = 1 ] && grep -qx 'HOST_LABEL="second"' "$CONF/config" \
  && ok "remote: a new --host-label replaces the old line instead of adding one" \
  || fail "remote: a new --host-label replaces the old line instead of adding one" "config: $(cat "$CONF/config")"
remote --ntfy mytopic
grep -qx 'HOST_LABEL="second"' "$CONF/config" && grep -qx 'MIN_SECONDS=45' "$CONF/config" \
  && ok "remote: a run without --host-label keeps the label and the rest of config" \
  || fail "remote: a run without --host-label keeps the label and the rest of config" "config: $(cat "$CONF/config")"

# ===== install.sh =====

LOCAL_NOTIFY="$HERE/notify.sh"

# --- a fresh machine, no ~/.claude yet ---
new_home
local_install --ntfy mytopic
[ "$RC" = 0 ] && ok "local: a fresh HOME installs cleanly" \
  || fail "local: a fresh HOME installs cleanly" "exit $RC, stderr: $ERR"
expect_hooks "$LOCAL_NOTIFY" "local"
app_shape_ok "$LOCAL_NOTIFY" && ok "local: the app recognises the shape as installed" \
  || fail "local: the app recognises the shape as installed" "got: $(jq -c .hooks "$SETTINGS")"
[ "$(cat "$CONF/ntfy-topic")" = "mytopic" ] && ok "local: ntfy-topic holds the topic" \
  || fail "local: ntfy-topic holds the topic" "got: $(cat "$CONF/ntfy-topic" 2>&1)"
case "$OUT" in *"WOULD SEND"*) ok "local: the test event goes through the sender";;
  *) fail "local: the test event goes through the sender" "got: $OUT";; esac
local_install --ntfy mytopic
[ "$(command_count | tr -d ' \n')" = "111" ] && ok "local: a second run leaves one command per event" \
  || fail "local: a second run leaves one command per event" "got: $(jq -c .hooks "$SETTINGS")"

# --- a checkout under a directory with a space ---
#
# The path was written unquoted, so every hook died with "No such file or
# directory" at the first word of the path. Run the written command the way
# Claude Code will and require the sender to answer.
new_home
REPO="$SANDBOX/repo with space"; mkdir -p "$REPO"
cp "$HERE/install.sh" "$HERE/notify.sh" "$REPO/"
run bash "$REPO/install.sh" --ntfy mytopic
cmd="$(commands Stop)"
hook_out="$(printf '{"session_id":"s","cwd":"/tmp/repo"}' | bash -c "$cmd" 2>&1)"
case "$hook_out" in *"WOULD SEND"*) ok "local: a hook written from a path with a space runs";;
  *) fail "local: a hook written from a path with a space runs" "command [$cmd] gave: $hook_out";; esac

# --- a moved checkout replaces its old hooks instead of posting twice ---
new_home
mkdir -p "$HOME/.claude"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash /old/place/notify.sh stop"}]}]}}' > "$SETTINGS"
local_install --ntfy mytopic
[ "$(commands Stop)" = "bash \"$LOCAL_NOTIFY\" stop" ] \
  && ok "local: an older notify.sh hook at another path is replaced" \
  || fail "local: an older notify.sh hook at another path is replaced" "got: $(commands Stop)"

# --- and the app's install replaces the checkout's, the upgrade path ---
remote --ntfy mytopic
[ "$(command_count | tr -d ' \n')" = "111" ] && app_shape_ok "$REMOTE_NOTIFY" \
  && ok "remote over local: one command per event, all pointing at ~/.agent-inbox/bin" \
  || fail "remote over local: one command per event, all pointing at ~/.agent-inbox/bin" "got: $(jq -c .hooks "$SETTINGS")"

# --- corrupt settings.json, same refusal ---
new_home
mkdir -p "$HOME/.claude"
printf '[1, 2' > "$SETTINGS"
local_install --ntfy mytopic
[ "$RC" != 0 ] && [ "$(cat "$SETTINGS")" = '[1, 2' ] && [ ! -e "$CONF/ntfy-topic" ] \
  && ok "local: invalid JSON exits non-zero, leaves the file, writes no topic" \
  || fail "local: invalid JSON exits non-zero, leaves the file, writes no topic" "exit $RC, file: $(cat "$SETTINGS"), stderr: $ERR"
case "$ERR" in *"not valid JSON"*) ok "local: and says why";; *) fail "local: and says why" "stderr: $ERR";; esac

# --- usage errors write no config and no hooks ---
new_home
local_install --ntfy
[ "$RC" != 0 ] && [ ! -e "$SETTINGS" ] && [ ! -e "$CONF/ntfy-topic" ] \
  && ok "local: --ntfy with no topic is a usage error that wires nothing" \
  || fail "local: --ntfy with no topic is a usage error that wires nothing" "exit $RC, home: $(ls -AR "$HOME")"
case "$ERR" in *usage:*) ok "local: and prints usage";; *) fail "local: and prints usage" "stderr: $ERR";; esac
local_install
[ "$RC" != 0 ] && [ ! -e "$SETTINGS" ] && ok "local: no arguments is a usage error that wires nothing" \
  || fail "local: no arguments is a usage error that wires nothing" "exit $RC"

# --- no jq ---
new_home
NOJQ="$SANDBOX/bin"; mkdir -p "$NOJQ"
for t in dirname cat mkdir chmod; do ln -s "$(command -v "$t")" "$NOJQ/$t"; done
PATH="$NOJQ" run "$BASH" "$HERE/install.sh" --ntfy mytopic
[ "$RC" != 0 ] && [ ! -e "$SETTINGS" ] && [ ! -e "$CONF" ] \
  && ok "local: without jq it exits non-zero and writes nothing" \
  || fail "local: without jq it exits non-zero and writes nothing" "exit $RC, home: $(ls -A "$HOME")"
case "$ERR" in *jq*) ok "local: and names jq";; *) fail "local: and names jq" "stderr: $ERR";; esac

# ===== setup-mac.sh =====
#
# Not run end to end: it downloads a DMG and drives the app. Its syntax and
# its usage path are checked, the usage path also the way the README invokes
# it, piped into bash, where $0 is "bash" and a usage that read itself back
# from $0 printed a sed error instead.
bash -n "$HERE/setup-mac.sh" && ok "setup-mac: parses" || fail "setup-mac: parses" "bash -n failed"
new_home
run bash "$HERE/setup-mac.sh" --help
[ "$RC" != 0 ] && [ -z "$(ls -A "$HOME")" ] && ok "setup-mac: --help exits non-zero and writes nothing" \
  || fail "setup-mac: --help exits non-zero and writes nothing" "exit $RC, home: $(ls -A "$HOME")"
case "$ERR" in *"--ntfy <topic>"*) ok "setup-mac: and prints usage";;
  *) fail "setup-mac: and prints usage" "stderr: $ERR";; esac
bash -s -- --help < "$HERE/setup-mac.sh" >"$WORK/out" 2>"$WORK/err"; RC=$?; ERR="$(cat "$WORK/err")"
case "$ERR" in *"usage:"*"--ntfy <topic>"*) ok "setup-mac: piped into bash, usage still prints";;
  *) fail "setup-mac: piped into bash, usage still prints" "exit $RC, stderr: $ERR";; esac

echo
echo "$PASS checks passed"
