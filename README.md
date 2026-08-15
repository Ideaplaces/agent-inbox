# Agent Inbox

**Native Mac notifications for every Claude Code session that finishes or needs you — across all your machines.**

<img src="docs/menubar-inbox.png" alt="Menubar badge showing 109 sessions waiting and 96 finished, with a dropdown listing each session by repo, host, and time" width="600">

If you run several Claude Code sessions in parallel (some local, some over SSH on a dev box), the bottleneck isn't the agents — it's remembering who finished what and who is sitting blocked on a permission prompt. Agent Inbox flips that around: sessions interrupt *you*.

- 🖐️ **"Needs you"** — an agent hit a permission prompt or is waiting for input
- ✅ **"Finished"** — a turn completed, with how long it took and the agent's closing words
- 🧵 **Context on every message** — what the conversation is about and what you last asked, so a ping from a two-day-old session still rings the right bell
- 📌 **Sticky menubar inbox** — a `🖐️2 ✅3` badge that stays until you mark it read. Go for coffee, come back, see who's waiting.

It's ~400 lines of bash. No server to run, no app to install (beyond two brew formulas), no account required.

```
senders (Claude Code hooks)         transport                surface (your Mac)
───────────────────────────   ────────────────────   ─────────────────────────────
laptop sessions   ─ notify.sh ─┐   ntfy.sh topic    ┌─ popup (terminal-notifier)
dev-box sessions  ─ notify.sh ─┼─→      or         ─┤
any other machine ─ notify.sh ─┘   Discord channel  └─ menubar badge (SwiftBar)
```

## Quickstart (ntfy — 2 minutes, no accounts)

[ntfy.sh](https://ntfy.sh) is a free, open-source pub/sub notification service. There's no signup, no bot, no webhook: a channel is just a topic name you invent. Anyone who knows the topic can read it, **so generate a long random one** — it's effectively the password.

```bash
git clone https://github.com/Ideaplaces/agent-inbox.git && cd agent-inbox

TOPIC="agent-inbox-$(whoami)-$(openssl rand -hex 8)"   # keep this string safe
echo $TOPIC

./install.sh --ntfy $TOPIC                # on EVERY machine where Claude Code runs
                                          # (over SSH too: clone + run there as well)

brew install terminal-notifier && brew install --cask swiftbar
./install-mac-watcher.sh --ntfy $TOPIC    # on the Mac that should get notified
```

Restart any running Claude Code sessions to pick up the hooks. Want phone push too? Install the ntfy iOS/Android app and subscribe to the same topic.

## What you get

| Hook event | Meaning | Behavior |
|------------|---------|----------|
| `UserPromptSubmit` | You handed work to the agent | Records a start timestamp (no notification) |
| `Stop` | Agent finished its turn | **✅** with duration + the agent's closing words — turns under `MIN_SECONDS` (45s) are suppressed so quick back-and-forth doesn't spam you |
| `Notification` | Agent needs permission or is idle waiting | **🖐️** with the reason and what the agent just asked |

A notification looks like:

```
🖐️ my-app @ devbox
🧵 Refactor the checkout flow to use the new payments SDK   ← conversation summary
🗣 ok now handle the refund path too                        ← your latest message
Claude needs your permission to use Bash                    ← why it pinged
❯ Should I run the migration against staging first?         ← what it's waiting on
```

**Click an item to jump to that session** — it opens the working directory in VS Code, over Remote-SSH when the session runs on another machine (the host label doubles as the SSH host alias). The popup itself opens the transport history.

**Items expire on keyboard time, not wall time.** An item clears after `EXPIRE_MINUTES` (default 5) of you actually being at the Mac, so while you work the list stays short instead of piling into noise. The clock stops when you step away, so a coffee-break backlog is still waiting when you return — and starts draining only once you are back. Set `EXPIRE_MINUTES=0` to keep everything until "Mark all read".

## ⚠️ Your conversation content travels through the transport

Notification bodies include snippets of your prompts and Claude's replies, plus repo names and working directory paths. That means:

- **ntfy**: use a long unguessable topic (anyone with the topic string can read your messages), or [self-host ntfy](https://docs.ntfy.sh/install/) and set `NTFY_SERVER`.
- **Discord**: use a private channel.
- Either way, don't point this at a shared or public channel, and think twice if you work on sensitive codebases.

## Alternative transport: Discord

Slightly more setup, but you get a browsable channel history that doubles as a catch-up inbox, plus phone push through the Discord app you probably already run.

1. Create a Discord bot ([developer portal](https://discord.com/developers/applications)), invite it to your server with permissions to manage channels and webhooks.
2. Provision a private channel + webhook:
   ```bash
   AGENT_INBOX_GUILD=<server-id> AGENT_INBOX_BOT_TOKEN=<bot-token> \
     ./setup-user.sh <name> <your-discord-user-id>
   ```
   It prints the exact install commands to run next.
3. Senders: `./install.sh --discord-webhook '<webhook-url>'`
4. Mac: `./install-mac-watcher.sh --discord '<bot-token>' <channel-id> <guild-id>`

The bot token is only needed on the Mac (reading messages back); sending machines just need the webhook URL.

**Azure Key Vault users:** set `AGENT_INBOX_VAULT` and use `--keyvault <name>` on both installers to skip passing secrets around.

## Config

Optional `~/.agent-inbox/config`, sourced by the scripts:

```bash
MIN_SECONDS=45                  # sender: ignore turns shorter than this
HOST_LABEL="mac"                # sender: hostname shown in messages
POLL_SECONDS=15                 # watcher: poll interval
NOTIFY_SOUND=""                 # watcher: silent by default; "Glass"/"Ping"/... for a sound
EXPIRE_MINUTES=5                # menubar: clear items after N min at the keyboard (0 = never)
IDLE_THRESHOLD=90               # menubar: seconds of no input before you count as away
NTFY_SERVER="https://ntfy.sh"   # self-hosted ntfy instance
```

Runtime state lives in `~/.agent-inbox/`: transport config (`ntfy-topic`, `webhook-url`, `bot-token`, `channel-id`, `guild-id`), cursors (`last-id`, `ntfy-cursor`), `unread.log` (menubar inbox), `watcher.log`.

## Requirements

- **Senders** (any OS Claude Code runs on): `bash`, `jq`, `curl`
- **Mac surface**: macOS, [terminal-notifier](https://github.com/julienXX/terminal-notifier), [SwiftBar](https://swiftbar.app) (both `brew install`), plus `jq`/`curl`

## How it works

`install.sh` merges three hooks into `~/.claude/settings.json` (idempotent, backs the file up first). On `Stop` and `Notification`, `notify.sh` reads the session transcript, extracts the context lines, and posts to your transport. On the Mac, `watch-mac.sh` runs as a launchd agent, polls the transport, raises a native notification, and appends to `unread.log`, which the SwiftBar plugin renders as the sticky menubar inbox.

Uninstall: remove the three `agent-inbox` entries from `~/.claude/settings.json`, `launchctl unload ~/Library/LaunchAgents/com.agent-inbox.watcher.plist`, and delete `~/.agent-inbox/`.

## Roadmap

A richer Mac client: per-item read state, click-to-open the exact VS Code window for a waiting session, and cloud/remote agents in the same inbox.

## License

MIT
