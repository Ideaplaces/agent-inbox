#!/usr/bin/env bash
# agent-inbox sender install: run once per machine.
#
#   ./install.sh --ntfy <topic>              ntfy.sh transport (no account, no bot)
#   ./install.sh --discord-webhook <url>     Discord transport
#   ./install.sh --keyvault <name>           Azure Key Vault convenience (see below)
#
# 1. Configures the transport under ~/.agent-inbox/
# 2. Merges the UserPromptSubmit / Stop / Notification hooks into
#    ~/.claude/settings.json (backs the file up first, idempotent)
#
# --keyvault pulls the webhook URL from an Azure Key Vault secret named
# "discord-webhook-agent-inbox-<name>". Set AGENT_INBOX_VAULT to your vault
# (or put it in ~/.agent-inbox/config). Handy for teams that already keep
# secrets there; everyone else should use --ntfy or --discord-webhook.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="$SCRIPT_DIR/notify.sh"
CONF_DIR="$HOME/.agent-inbox"
SETTINGS="$HOME/.claude/settings.json"

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
[ -f "$NOTIFY" ] || { echo "notify.sh not found next to installer"; exit 1; }
chmod +x "$NOTIFY"
mkdir -p "$CONF_DIR"
[ -f "$CONF_DIR/config" ] && . "$CONF_DIR/config"

usage() {
  echo "usage: install.sh --ntfy <topic> | --discord-webhook <url> | --keyvault <name>" >&2
  exit 1
}

case "${1:-}" in
  --ntfy)
    TOPIC="${2:-}"; [ -n "$TOPIC" ] || usage
    printf '%s' "$TOPIC" > "$CONF_DIR/ntfy-topic"
    chmod 600 "$CONF_DIR/ntfy-topic"
    echo "ntfy transport configured (topic: $TOPIC on ${NTFY_SERVER:-https://ntfy.sh})"
    ;;
  --discord-webhook)
    URL="${2:-}"; [ -n "$URL" ] || usage
    printf '%s' "$URL" > "$CONF_DIR/webhook-url"
    chmod 600 "$CONF_DIR/webhook-url"
    echo "Discord transport configured"
    ;;
  --keyvault)
    NAME="${2:-}"; [ -n "$NAME" ] || usage
    VAULT="${AGENT_INBOX_VAULT:-}"
    [ -n "$VAULT" ] || { echo "set AGENT_INBOX_VAULT to your Azure Key Vault name"; exit 1; }
    command -v az >/dev/null || { echo "az is required for --keyvault"; exit 1; }
    printf '%s' "$NAME" > "$CONF_DIR/user"
    echo "Fetching webhook URL from Key Vault ($VAULT/discord-webhook-agent-inbox-$NAME)..."
    az keyvault secret show --vault-name "$VAULT" --name "discord-webhook-agent-inbox-$NAME" --query value -o tsv > "$CONF_DIR/webhook-url"
    chmod 600 "$CONF_DIR/webhook-url"
    ;;
  *)
    usage
    ;;
esac

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.agent-inbox"

TMP="$(mktemp)"
jq --arg n "$NOTIFY" '
  def ensure(ev; cmd):
    .hooks[ev] = ((.hooks[ev] // [])
      | map(select((.hooks // []) | any(.command == cmd) | not))
      + [{hooks: [{type: "command", command: cmd}]}]);
  .hooks = (.hooks // {})
  | ensure("UserPromptSubmit"; "bash \($n) prompt")
  | ensure("Stop";             "bash \($n) stop")
  | ensure("Notification";     "bash \($n) notification")
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"

echo "Hooks installed into $SETTINGS (backup at $SETTINGS.bak.agent-inbox)"
echo "Sending test notification..."
printf '{"session_id":"install-test","cwd":"%s","message":"agent-inbox sender installed on %s"}' "$PWD" "$(hostname -s)" \
  | bash "$NOTIFY" notification
echo "Done. Restart running Claude Code sessions to pick up the hooks."
