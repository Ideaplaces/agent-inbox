#!/usr/bin/env bash
# agent-inbox sender install: run once per machine.
#
#   ./install.sh --ntfy <topic>
#
# 1. Configures the transport under ~/.agent-inbox/
# 2. Merges the UserPromptSubmit / Stop / Notification hooks into
#    ~/.claude/settings.json (backs the file up first, idempotent)
#
# NTFY_SERVER in ~/.agent-inbox/config points this at a self-hosted instance,
# and ~/.agent-inbox/ntfy-token authenticates to one that requires it.
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
  echo "usage: install.sh --ntfy <topic>" >&2
  exit 1
}

case "${1:-}" in
  --ntfy)
    TOPIC="${2:-}"; [ -n "$TOPIC" ] || usage
    printf '%s' "$TOPIC" > "$CONF_DIR/ntfy-topic"
    chmod 600 "$CONF_DIR/ntfy-topic"
    echo "ntfy transport configured (topic: $TOPIC on ${NTFY_SERVER:-https://ntfy.sh})"
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
