#!/usr/bin/env bash
# agent-inbox per-developer provisioning: run ONCE per developer (any machine with az).
#
#   ./setup-user.sh <name> <discord-user-id> [bot-token-secret]
#   ./setup-user.sh luca 687429027862151186
#
# Creates (idempotently):
#   - private Discord channel  #agent-inbox-<name>   (visible to that user + their bot)
#   - a webhook on that channel
#   - Key Vault secret         discord-webhook-agent-inbox-<name>
#
# The bot token secret defaults to discord-bot-token-<name> (see
# ideaplaces-devops/discord/README.md for the bot-per-developer convention).
set -euo pipefail

NAME="${1:?usage: setup-user.sh <name> <discord-user-id> [bot-token-secret]}"
USER_ID="${2:?usage: setup-user.sh <name> <discord-user-id> [bot-token-secret]}"
BOT_SECRET="${3:-discord-bot-token-$NAME}"

GUILD=1462642831184232584   # IdeaPlaces server
VAULT=kv-ideaplaces
CHANNEL_NAME="agent-inbox-$NAME"
WEBHOOK_SECRET="discord-webhook-agent-inbox-$NAME"

TOKEN=$(az keyvault secret show --vault-name "$VAULT" --name "$BOT_SECRET" --query value -o tsv)
BOT_ID=$(curl -s -H "Authorization: Bot $TOKEN" https://discord.com/api/v10/users/@me | jq -r '.id')

CHANNEL_ID=$(curl -s -H "Authorization: Bot $TOKEN" "https://discord.com/api/v10/guilds/$GUILD/channels" \
  | jq -r --arg n "$CHANNEL_NAME" '.[] | select(.name==$n) | .id')
if [ -n "$CHANNEL_ID" ]; then
  echo "channel #$CHANNEL_NAME exists: $CHANNEL_ID"
else
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

az keyvault secret set --vault-name "$VAULT" --name "$WEBHOOK_SECRET" --value "$WH" --query name -o tsv >/dev/null
echo "Key Vault secret set: $WEBHOOK_SECRET"
echo ""
echo "Next, on each machine where $NAME runs Claude Code:   ./install.sh $NAME"
echo "And on $NAME's Mac (for native notifications):        ./install-mac-watcher.sh $NAME"
