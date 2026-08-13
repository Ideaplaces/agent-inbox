# Agent Inbox

Native Mac notifications for every Claude Code session that finishes or needs you — across all machines (Mac, chipdev Ubuntu, anywhere else), for every developer.

Discord is only the **transport and history** (a private `#agent-inbox-<name>` channel per developer). The surface is a watcher on your Mac that polls that channel and raises **native macOS notifications**. You don't need the Discord client open — though the channel doubles as a catch-up inbox on the phone or after being away.

```
senders (Claude Code hooks)          transport                 surface
───────────────────────────   ──────────────────────   ─────────────────────────
mac sessions      ─ notify.sh ─┐                       ┌─ watch-mac.sh (launchd)
chipdev sessions  ─ notify.sh ─┼─→ #agent-inbox-<name> ─┤   → native macOS
any other machine ─ notify.sh ─┘   (private, webhook)  └─   notifications
```

## What gets sent

| Hook event | Meaning | Behavior |
|------------|---------|----------|
| `UserPromptSubmit` | You handed work to the agent | Records a start timestamp (no notification) |
| `Stop` | Agent finished its turn | **✅ Finished** with duration + last-message snippet — only if the turn took ≥ `MIN_SECONDS` (default 45s), so quick back-and-forth doesn't spam |
| `Notification` | Agent needs permission or is idle waiting for input | **🖐️ Needs you** with the reason |

Every message carries repo name, host label, working directory, and short session id — with a dozen parallel sessions you always know who is talking.

## Setup

### Once per developer (any machine with az)

```bash
./setup-user.sh <name> <discord-user-id>     # e.g. ./setup-user.sh luca 687429027862151186
```

Creates the private `#agent-inbox-<name>` channel, its webhook, and the Key Vault secret `discord-webhook-agent-inbox-<name>`. Uses the developer's bot (`discord-bot-token-<name>`, see `ideaplaces-devops/discord/README.md`).

### On every machine where you run Claude Code (sender)

```bash
./install.sh <name>                          # e.g. ./install.sh chip
```

Merges the hooks into `~/.claude/settings.json` (idempotent, backs up first) and caches the webhook URL. Restart running Claude Code sessions to pick up the hooks.

### On your Mac (surface)

```bash
./install-mac-watcher.sh <name>
```

Installs a launchd agent (`com.ideaplaces.agent-inbox-watcher`) that polls the channel every 15s and raises native notifications (terminal-notifier if installed, else osascript). Log: `~/.agent-inbox/watcher.log`.

Requires `jq`, `curl`, and a logged-in `az` on each machine at install time (secrets are cached locally after that).

## Config

Optional `~/.agent-inbox/config` (sourced by both scripts):

```bash
MIN_SECONDS=45          # sender: ignore turns shorter than this
HOST_LABEL="mac"        # sender: hostname shown in messages
POLL_SECONDS=15         # watcher: Discord poll interval
```

## Infrastructure

- Discord channels: `#agent-inbox-<name>`, private to that developer, on the IdeaPlaces server (chip: `1537606385318109294`)
- Key Vault (`kv-ideaplaces`): `discord-webhook-agent-inbox-<name>` (webhook), `discord-bot-token-<name>` (watcher reads)
- Conventions: `ideaplaces-devops/discord/README.md`

## Roadmap

Phase 2 — rich Mac inbox client (persistent list, read/unread, click-to-open the VS Code window). Spec: docs.ideaplaces.com → Active Projects → Agent Inbox.
