# Agent Inbox

One place to see every Claude Code session that finished or needs you — across all machines (Mac, chipdev Ubuntu, anywhere else). Notifications land in the private Discord channel **#agent-inbox**, which reaches the Mac desktop, the phone, and keeps history like an inbox: come back after being away and scan what's waiting.

## How it works

Claude Code hooks on each machine call `notify.sh`, which posts a Discord embed via webhook:

| Hook event | Meaning | Behavior |
|------------|---------|----------|
| `UserPromptSubmit` | You handed work to the agent | Records a start timestamp (no notification) |
| `Stop` | Agent finished its turn | Posts **✅ Finished** with duration + last message snippet — only if the turn took ≥ `MIN_SECONDS` (default 45s), so quick back-and-forth doesn't spam |
| `Notification` | Agent needs permission or is idle waiting for input | Posts **🖐️ Needs you** with the reason |

Every message includes the repo name, host, working directory, and short session id, so with a dozen parallel sessions you always know who is talking.

## Install (once per machine)

```bash
git clone git@github.com:Ideaplaces/agent-inbox.git   # or use the ideaplaces-meta checkout
cd agent-inbox
./install.sh
```

Requires `jq`, `curl`, and a logged-in `az` (the webhook URL is pulled once from Key Vault `kv-ideaplaces/discord-webhook-agent-inbox` and cached at `~/.agent-inbox/webhook-url`). The installer merges the hooks into `~/.claude/settings.json` idempotently and sends a test notification.

## Config

Optional `~/.agent-inbox/config` (sourced by notify.sh):

```bash
MIN_SECONDS=45          # ignore turns shorter than this
HOST_LABEL="mac"        # override the hostname shown in messages
```

## Infrastructure

- Discord channel: `#agent-inbox` (id `1537606385318109294`, private to Chip) on the IdeaPlaces server
- Webhook secret: Key Vault `kv-ideaplaces` → `discord-webhook-agent-inbox`
- See `ideaplaces-devops/discord/README.md` for the server/bot conventions

## Roadmap

Phase 2 — a rich native Mac inbox client (actionable notifications, click-to-open VS Code window, read/unread state). Spec: https://docs.ideaplaces.com (ideaplaces-docs `docs/agent-inbox-spec.md`).
