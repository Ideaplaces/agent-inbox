#!/usr/bin/env bash
# Agent Inbox, set up on a Mac in one command.
#
#   curl -fsSL https://raw.githubusercontent.com/Ideaplaces/agent-inbox/main/setup-mac.sh \
#     | bash -s -- --ntfy <topic>
#
#   ... | bash -s -- --discord --bot-token <t> --channel-id <c> [--guild-id <g>] [--webhook <w>]
#   ... | bash -s -- --keyvault <name>        # Azure Key Vault: reads the secrets for you
#
# Installs the app, configures the transport, installs the Claude Code hooks,
# registers it to open at login, and launches it. Nothing to click.
#
# The app is normally configured through its setup window; this drives the same
# code paths through the CLI flags so a provisioning run needs no GUI.
set -euo pipefail

APP="/Applications/Agent Inbox.app"
BIN="$APP/Contents/MacOS/AgentInbox"
TAP="ideaplaces/tap/agent-inbox"
RELEASES="https://api.github.com/repos/Ideaplaces/agent-inbox/releases/latest"

TRANSPORT="" TOPIC="" SERVER="" BOT_TOKEN="" CHANNEL_ID="" GUILD_ID="" WEBHOOK=""
VAULT_NAME="" HOST_LABEL="$(scutil --get ComputerName 2>/dev/null || hostname -s)"

die() { echo "error: $*" >&2; exit 1; }

# The app's CLI writes to the login Keychain. If an item there was created by a
# differently-signed build, macOS asks permission with a dialog, and an
# LSUIElement app driven from a script has no way to show it: the call blocks
# forever and the script looks hung. Bound it and say what to do instead.
run_app() {
  "$BIN" "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge 45 ]; then
      kill "$pid" 2>/dev/null || true
      die "the app stopped responding while running: $*
This is usually macOS waiting on an invisible Keychain prompt, which happens
when an item was written by an earlier, differently-signed build. Clear it and
run this again:
  security delete-generic-password -s com.ideaplaces.agent-inbox -a discord-bot-token
  security delete-generic-password -s com.ideaplaces.agent-inbox -a discord-webhook-url"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" || die "the app exited with an error while running: $*"
}

usage() {
  sed -n '2,12p' "$0" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ntfy)        TRANSPORT=ntfy;    TOPIC="${2:-}";      shift 2 ;;
    --server)      SERVER="${2:-}";                        shift 2 ;;
    --discord)     TRANSPORT=discord;                      shift ;;
    --bot-token)   BOT_TOKEN="${2:-}";                     shift 2 ;;
    --channel-id)  CHANNEL_ID="${2:-}";                    shift 2 ;;
    --guild-id)    GUILD_ID="${2:-}";                      shift 2 ;;
    --webhook)     WEBHOOK="${2:-}";                       shift 2 ;;
    --keyvault)    TRANSPORT=discord; VAULT_NAME="${2:-}"; shift 2 ;;
    --host-label)  HOST_LABEL="${2:-}";                    shift 2 ;;
    *) usage ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "this is the Mac installer; use install-remote.sh on other machines"
[ -n "$TRANSPORT" ] || usage

# --keyvault is a convenience for teams already keeping secrets there. It reads
# the same names setup-user.sh writes.
if [ -n "$VAULT_NAME" ]; then
  command -v az >/dev/null || die "--keyvault needs the az CLI, and an active az login"
  VAULT="${AGENT_INBOX_VAULT:-kv-ideaplaces}"
  echo "==> Reading secrets for '$VAULT_NAME' from $VAULT"
  BOT_TOKEN="$(az keyvault secret show --vault-name "$VAULT" --name "discord-bot-token-$VAULT_NAME" --query value -o tsv)"
  WEBHOOK="$(az keyvault secret show --vault-name "$VAULT" --name "discord-webhook-agent-inbox-$VAULT_NAME" --query value -o tsv)"
  [ -n "$BOT_TOKEN" ] && [ -n "$WEBHOOK" ] || die "could not read both secrets from $VAULT"
  # The channel id is not a secret, so derive it from the webhook rather than
  # asking for it: a webhook URL always names the channel it posts to.
  if [ -z "$CHANNEL_ID" ]; then
    CHANNEL_ID="$(curl -m 10 -s "$WEBHOOK" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("channel_id",""))' 2>/dev/null || true)"
    GUILD_ID="${GUILD_ID:-$(curl -m 10 -s "$WEBHOOK" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("guild_id",""))' 2>/dev/null || true)}"
  fi
  [ -n "$CHANNEL_ID" ] || die "could not resolve the channel id from the webhook; pass --channel-id"
fi

echo "==> Installing the app"
if [ -d "$APP" ]; then
  echo "    already in /Applications"
elif command -v brew >/dev/null; then
  brew install --cask "$TAP"
else
  # No Homebrew: take the notarized DMG straight from the latest release.
  echo "    no Homebrew, downloading the latest release"
  URL="$(curl -fsSL "$RELEASES" | /usr/bin/python3 -c \
    'import json,sys; print(next(a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"].endswith(".dmg")))')"
  TMP="$(mktemp -d)"
  curl -fsSL "$URL" -o "$TMP/AgentInbox.dmg"
  # Read-only mount is all we need, and it works on machines that refuse
  # writable disk images.
  MOUNT="$(hdiutil attach "$TMP/AgentInbox.dmg" -nobrowse -noverify \
    | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
  [ -n "$MOUNT" ] || die "could not mount the downloaded disk image"
  cp -R "$MOUNT/Agent Inbox.app" /Applications/
  hdiutil detach "$MOUNT" -quiet || true
  rm -rf "$TMP"
  # Gatekeeper quarantines anything downloaded; the app is notarized, so this
  # only skips the "downloaded from the internet" prompt.
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
fi
[ -x "$BIN" ] || die "the app did not install at $APP"

echo "==> Configuring the transport"
case "$TRANSPORT" in
  ntfy)
    [ -n "$TOPIC" ] || die "--ntfy needs a topic"
    ARGS=(--configure --transport ntfy --topic "$TOPIC" --host-label "$HOST_LABEL")
    [ -n "$SERVER" ] && ARGS+=(--server "$SERVER")
    ;;
  discord)
    [ -n "$BOT_TOKEN" ] && [ -n "$CHANNEL_ID" ] || die "Discord needs --bot-token and --channel-id"
    ARGS=(--configure --transport discord --bot-token "$BOT_TOKEN"
          --channel-id "$CHANNEL_ID" --host-label "$HOST_LABEL")
    [ -n "$GUILD_ID" ] && ARGS+=(--guild-id "$GUILD_ID")
    [ -n "$WEBHOOK" ] && ARGS+=(--webhook "$WEBHOOK")
    ;;
esac
run_app "${ARGS[@]}"

echo "==> Installing the Claude Code hooks"
run_app --install-hooks

echo "==> Opening at login"
run_app --register-login-item

echo "==> Launching"
open "$APP"

cat <<DONE

Done. Agent Inbox is in your menubar, reporting as "$HOST_LABEL".

Restart any Claude Code sessions that were already running, or they will not
pick up the hooks.

For your other machines, including a dev box over SSH:
  curl -fsSL https://raw.githubusercontent.com/Ideaplaces/agent-inbox/main/install-remote.sh \\
    | bash -s -- <same transport flags> --host-label <that machine's name>
DONE
