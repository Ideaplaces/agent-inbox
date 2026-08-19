#!/usr/bin/env bash
# agent-inbox sender install, over curl. Run on any machine where Claude Code
# runs, including a dev box you only reach over SSH. Nothing to clone.
#
#   curl -fsSL https://raw.githubusercontent.com/Ideaplaces/agent-inbox/main/install-remote.sh \
#     | bash -s -- --ntfy <topic>
#   curl -fsSL .../install-remote.sh | bash -s -- --discord-webhook '<url>'
#
# Optional:
#   --host-label <name>   how this machine is named in messages. Defaults to
#                         the short hostname; set it to this machine's SSH host
#                         alias so the Mac inbox can open sessions over
#                         Remote-SSH.
set -euo pipefail

CONF_DIR="$HOME/.agent-inbox"
BIN_DIR="$CONF_DIR/bin"
SETTINGS="$HOME/.claude/settings.json"
RAW_BASE="${AGENT_INBOX_RAW_BASE:-https://raw.githubusercontent.com/Ideaplaces/agent-inbox/main}"
HOST_LABEL=""
TRANSPORT=""
VALUE=""

usage() {
  echo "usage: install-remote.sh --ntfy <topic> | --discord-webhook <url> [--host-label <name>]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ntfy)             TRANSPORT=ntfy;    VALUE="${2:-}"; shift 2 || usage ;;
    --discord-webhook)  TRANSPORT=discord; VALUE="${2:-}"; shift 2 || usage ;;
    --host-label)       HOST_LABEL="${2:-}"; shift 2 || usage ;;
    *) usage ;;
  esac
done
[ -n "$TRANSPORT" ] && [ -n "$VALUE" ] || usage

for tool in jq curl; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done

mkdir -p "$BIN_DIR"
echo "==> Fetching notify.sh"
curl -fsSL "$RAW_BASE/notify.sh" -o "$BIN_DIR/notify.sh"
chmod +x "$BIN_DIR/notify.sh"

case "$TRANSPORT" in
  ntfy)
    printf '%s' "$VALUE" > "$CONF_DIR/ntfy-topic"
    chmod 600 "$CONF_DIR/ntfy-topic"
    echo "==> ntfy transport configured"
    ;;
  discord)
    printf '%s' "$VALUE" > "$CONF_DIR/webhook-url"
    chmod 600 "$CONF_DIR/webhook-url"
    echo "==> Discord transport configured"
    ;;
esac

# Only write a host label if the user asked for one, so re-running the
# installer never silently renames a machine already known by another name.
if [ -n "$HOST_LABEL" ]; then
  if [ -f "$CONF_DIR/config" ] && grep -q '^HOST_LABEL=' "$CONF_DIR/config"; then
    sed -i.bak "s|^HOST_LABEL=.*|HOST_LABEL=\"$HOST_LABEL\"|" "$CONF_DIR/config"
    rm -f "$CONF_DIR/config.bak"
  else
    printf 'HOST_LABEL="%s"\n' "$HOST_LABEL" >> "$CONF_DIR/config"
  fi
  echo "==> This machine reports as \"$HOST_LABEL\""
fi

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.agent-inbox"

TMP="$(mktemp)"
jq --arg n "$BIN_DIR/notify.sh" '
  def ensure(ev; cmd):
    .hooks[ev] = ((.hooks[ev] // [])
      | map(if (.hooks // []) | any(.command | test("notify\\.sh"))
            then .hooks |= map(select(.command | test("notify\\.sh") | not))
            else . end)
      | map(select((.hooks // []) | length > 0))
      + [{hooks: [{type: "command", command: cmd}]}]);
  .hooks = (.hooks // {})
  | ensure("UserPromptSubmit"; "bash \"\($n)\" prompt")
  | ensure("Stop";             "bash \"\($n)\" stop")
  | ensure("Notification";     "bash \"\($n)\" notification")
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"

echo "==> Hooks installed into $SETTINGS (backup at $SETTINGS.bak.agent-inbox)"
echo "==> Sending a test event"
printf '{"session_id":"install-test","cwd":"%s","message":"agent-inbox installed on %s"}' \
  "$PWD" "$(hostname -s)" | bash "$BIN_DIR/notify.sh" notification
echo
echo "Done. Restart any running Claude Code sessions to pick up the hooks."
