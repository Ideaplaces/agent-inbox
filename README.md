# Agent Inbox

Native Mac notifications for every Claude Code session that finishes or needs you — across all machines, for every developer.

Claude Code hooks on each machine send events through a transport; a watcher on your Mac turns them into native macOS notifications plus a **sticky menubar inbox** (a `🖐️2 ✅3` badge that stays until you mark it read — go for coffee, come back, the menubar tells you who finished and who is blocked).

```
senders (Claude Code hooks)         transport                surface (your Mac)
───────────────────────────   ────────────────────   ─────────────────────────────
laptop sessions   ─ notify.sh ─┐  Discord channel   ┌─ popup (terminal-notifier)
dev-box sessions  ─ notify.sh ─┼─→      or         ─┤
any other machine ─ notify.sh ─┘  ntfy.sh topic     └─ menubar badge (SwiftBar)
```

## What gets sent

| Hook event | Meaning | Behavior |
|------------|---------|----------|
| `UserPromptSubmit` | You handed work to the agent | Records a start timestamp (no notification) |
| `Stop` | Agent finished its turn | **✅ Finished** with duration + the agent's closing words — turns under `MIN_SECONDS` (45s) are suppressed so quick back-and-forth doesn't spam |
| `Notification` | Agent needs permission or is idle waiting | **🖐️ Needs you** with the reason and what the agent just asked |

Every event leads with a 🧵 line saying **what the chat is about** (Claude Code's own session summary, or your first prompt), so with a dozen parallel sessions each notification rings the right bell.

## Choose a transport

Both ends must use the same one. Configuring both also works (events go to both).

### ntfy.sh — simplest, zero accounts (recommended if you're not on IdeaPlaces infra)

[ntfy.sh](https://ntfy.sh) is a free, open-source pub/sub notification service most people haven't heard of: there is **no signup, no bot, no webhook** — a channel is just a topic name you invent. Anyone who knows the topic can post/read, so make it long and unguessable (it's effectively the password):

```bash
TOPIC="agent-inbox-$(whoami)-$(openssl rand -hex 8)"
./install.sh --ntfy $TOPIC              # every machine where Claude Code runs
./install-mac-watcher.sh --ntfy $TOPIC  # your Mac
```

Bonus: install the ntfy iOS/Android app and subscribe to the same topic for phone push. Self-hosters can point `NTFY_SERVER` at their own instance.

### Discord — richer history (what IdeaPlaces uses)

A private channel per developer doubles as a browsable catch-up inbox with phone push via the Discord app. Requires a bot that can create channels/webhooks and read messages.

IdeaPlaces setup (bots + Key Vault already in place, see `ideaplaces-devops/discord/README.md`):

```bash
./setup-user.sh <name> <discord-user-id>   # once, from any machine with az login
./install.sh <name>                        # every machine where Claude Code runs
./install-mac-watcher.sh <name>            # your Mac
```

Outside IdeaPlaces: create a Discord bot, invite it to your server, then put the webhook URL in `~/.agent-inbox/webhook-url` and the bot token + channel id in `~/.agent-inbox/bot-token` / `~/.agent-inbox/channel-id` (the installers' Key Vault fetch is IdeaPlaces-specific).

## Mac surface

```bash
brew install terminal-notifier && brew install --cask swiftbar   # first time
```

`install-mac-watcher.sh` installs a launchd agent (`com.ideaplaces.agent-inbox-watcher`) that polls the transport every 15s and surfaces each event twice:

- **Popup**: native notification; clicking opens the transport history (Discord channel or ntfy topic page).
- **Sticky menubar inbox** (SwiftBar): badge + dropdown that persist until "Mark all read".

Popups are macOS *banners* (they slide away) by default; the menubar badge is the persistent surface. If you want popups to stay on screen too: System Settings → Notifications → terminal-notifier → alert style **Alerts**.

## Config

Optional `~/.agent-inbox/config` (sourced by both scripts):

```bash
MIN_SECONDS=45          # sender: ignore turns shorter than this
HOST_LABEL="mac"        # sender: hostname shown in messages
POLL_SECONDS=15         # watcher: poll interval
NTFY_SERVER="https://ntfy.sh"   # self-hosted ntfy instance
NTFY_TOPIC="..."        # alternative to the ntfy-topic file
```

State lives in `~/.agent-inbox/`: `webhook-url`, `bot-token`, `channel-id`, `ntfy-topic`, `last-id`/`ntfy-cursor` (watcher cursors), `unread.log` (menubar inbox), `watcher.log`.

## IdeaPlaces infrastructure

- Discord channels: `#agent-inbox-<name>`, private per developer (chip: `1537606385318109294`)
- Key Vault (`kv-ideaplaces`): `discord-webhook-agent-inbox-<name>`, `discord-bot-token-<name>`
- Conventions: `ideaplaces-devops/discord/README.md`

## Roadmap

Phase 2 — rich Mac inbox client (per-item read state, click-to-open the exact VS Code window, C3 cloud agents in the same inbox). Spec: docs.ideaplaces.com → Active Projects → Agent Inbox.
