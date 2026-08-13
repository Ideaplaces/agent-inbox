#!/usr/bin/env bash
# agent-inbox sender install: run once per machine, per developer.
#
#   ./install.sh <name>        e.g.  ./install.sh chip
#
# 1. Caches the developer's Discord webhook URL from Azure Key Vault
#    (requires az login) into ~/.agent-inbox/webhook-url
# 2. Merges the UserPromptSubmit / Stop / Notification hooks into
#    ~/.claude/settings.json (backs the file up first, idempotent)
set -euo pipefail

NAME="${1:?usage: install.sh <name>   (e.g. install.sh chip)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="$SCRIPT_DIR/notify.sh"
CONF_DIR="$HOME/.agent-inbox"
SETTINGS="$HOME/.claude/settings.json"

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v az >/dev/null || { echo "az is required"; exit 1; }
[ -f "$NOTIFY" ] || { echo "notify.sh not found next to installer"; exit 1; }
chmod +x "$NOTIFY"

mkdir -p "$CONF_DIR"
echo "$NAME" > "$CONF_DIR/user"
echo "Fetching webhook URL from Key Vault (discord-webhook-agent-inbox-$NAME)..."
az keyvault secret show --vault-name kv-ideaplaces --name "discord-webhook-agent-inbox-$NAME" --query value -o tsv > "$CONF_DIR/webhook-url"
chmod 600 "$CONF_DIR/webhook-url"

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
