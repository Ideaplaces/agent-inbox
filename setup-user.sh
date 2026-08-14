#!/usr/bin/env bash
# agent-inbox Discord provisioning: creates a private #agent-inbox-<name>
# channel and its webhook. Run once per person. Idempotent.
#
#   AGENT_INBOX_GUILD=<server-id> AGENT_INBOX_BOT_TOKEN=<bot-token> \
#     ./setup-user.sh <name> <discord-user-id>
#
# Both values can also live in ~/.agent-inbox/config. If AGENT_INBOX_VAULT is
# set, the bot token is read from Azure Key Vault (secret: discord-bot-token-<name>,
# override with $3) and the resulting webhook is stored back as
# discord-webhook-agent-inbox-<name> — a convenience for teams already on Key
# Vault; everyone else just gets the webhook URL printed.
#
# Only needed for the Discord transport. The ntfy transport needs no setup:
# pick a topic and run ./install.sh --ntfy <topic>.
set -euo pipefail

CONF_DIR="$HOME/.agent-inbox"
[ -f "$CONF_DIR/config" ] && . "$CONF_DIR/config"

NAME="${1:?usage: setup-user.sh <name> <discord-user-id> [bot-token-secret]}"
USER_ID="${2:?usage: setup-user.sh <name> <discord-user-id> [bot-token-secret]}"
BOT_SECRET="${3:-discord-bot-token-$NAME}"
GUILD="${AGENT_INBOX_GUILD:?set AGENT_INBOX_GUILD to your Discord server id}"
VAULT="${AGENT_INBOX_VAULT:-}"
CHANNEL_NAME="agent-inbox-$NAME"

if [ -n "${AGENT_INBOX_BOT_TOKEN:-}" ]; then
  TOKEN="$AGENT_INBOX_BOT_TOKEN"
elif [ -n "$VAULT" ]; then
  TOKEN=$(az keyvault secret show --vault-name "$VAULT" --name "$BOT_SECRET" --query value -o tsv)
else
  echo "set AGENT_INBOX_BOT_TOKEN (or AGENT_INBOX_VAULT to read it from Key Vault)" >&2
  exit 1
fi

BOT_ID=$(curl -s -H "Authorization: Bot $TOKEN" https://discord.com/api/v10/users/@me | jq -r '.id')

CHANNEL_ID=$(curl -s -H "Authorization: Bot $TOKEN" "https://discord.com/api/v10/guilds/$GUILD/channels" \
  | jq -r --arg n "$CHANNEL_NAME" '.[] | select(.name==$n) | .id')
if [ -n "$CHANNEL_ID" ]; then
  echo "channel #$CHANNEL_NAME exists: $CHANNEL_ID"
else
  # Deny @everyone VIEW_CHANNEL (1024); allow the owner and the bot.
  CHANNEL_ID=$(curl -s -X POST -H "Authorization: Bot $TOKEN" -H "Content-Type: application/json" \
    "https://discord.com/api/v10/guilds/$GUILD/channels" \
    -d "{\"name\":\"$CHANNEL_NAME\",\"type\":0,\"topic\":\"Claude Code agent inbox for $NAME: finished sessions and agents waiting for input\",\"permission_overwrites\":[{\"id\":\"$GUILD\",\"type\":0,\"deny\":\"1024\"},{\"id\":\"$USER_ID\",\"type\":1,\"allow\":\"1024\"},{\"id\":\"$BOT_ID\",\"type\":1,\"allow\":\"1024\"}]}" \
    | jq -r '.id')
  echo "channel #$CHANNEL_NAME created: $CHANNEL_ID"
fi

WH=$(curl -s -H "Authorization: Bot $TOKEN" "https://discord.com/api/v10/channels/$CHANNEL_ID/webhooks" | jq -r '.[0].url // empty')
if [ -z "$WH" ]; then
  WH=$(curl -s -X POST -H "Authorization: Bot $TOKEN" -H "Content-Type: application/json" \
    "https://discord.com/api/v10/channels/$CHANNEL_ID/webhooks" -d '{"name":"Agent Inbox"}' | jq -r '.url')
  echo "webhook created"
else
  echo "webhook exists"
fi

echo ""
if [ -n "$VAULT" ]; then
  az keyvault secret set --vault-name "$VAULT" --name "discord-webhook-agent-inbox-$NAME" --value "$WH" --query name -o tsv >/dev/null
  echo "Key Vault secret set: discord-webhook-agent-inbox-$NAME"
  echo "Senders:  ./install.sh --keyvault $NAME"
  echo "Mac:      ./install-mac-watcher.sh --keyvault $NAME"
else
  echo "Senders:  ./install.sh --discord-webhook '$WH'"
  echo "Mac:      ./install-mac-watcher.sh --discord '<bot-token>' $CHANNEL_ID $GUILD"
fi
