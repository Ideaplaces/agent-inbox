# Agent Inbox

**Native Mac notifications for every Claude Code session that finishes or needs you — across all your machines.**

If you run several Claude Code sessions in parallel (some local, some over SSH on a dev box), the bottleneck isn't the agents — it's remembering who finished what and who is sitting blocked on a permission prompt. Agent Inbox flips that around: sessions interrupt *you*.

- 🖐️ **"Needs you"** — an agent hit a permission prompt or is waiting for input
- ✅ **"Finished"** — a turn completed, with how long it took and the agent's closing words
- 🧵 **Context on every message** — what the conversation is about and what you last asked, so a ping from a two-day-old session still rings the right bell
- 📌 **Sticky menubar inbox** — a `🖐️2 ✅3` badge that stays until you mark it read. Go for coffee, come back, see who's waiting.

A native menubar app on the Mac, plain bash on every machine that sends. No server to run, no service to sign up for, no account required.

```
senders (Claude Code hooks)         transport              surface (your Mac)
───────────────────────────   ────────────────────   ─────────────────────────
laptop sessions   ─ notify.sh ─┐   ntfy.sh topic    ┌─ native notifications
dev-box sessions  ─ notify.sh ─┼─→      or         ─┤
any other machine ─ notify.sh ─┘   Discord channel  └─ menubar inbox
```

## Quickstart

**On your Mac:**

```bash
brew install --cask ideaplaces/tap/agent-inbox
```

Or download the latest `AgentInbox.dmg` from
[Releases](https://github.com/Ideaplaces/agent-inbox/releases) and drag it to Applications.
Either way the app is signed and notarized, so it opens without a Gatekeeper warning, and
it updates itself from then on.

Open it and the setup window walks you through three things: pick a transport, wire up this
Mac, and copy the one-line command for your other machines. Nothing to clone, no
dependencies to install.

Prefer to build it yourself? See [mac/README.md](mac/README.md) — it is `./mac/build.sh`
and a Swift toolchain.

**On every other machine** where Claude Code runs, including a dev box you only reach
over SSH, paste the command the app gives you:

```bash
curl -fsSL https://raw.githubusercontent.com/Ideaplaces/agent-inbox/main/install-remote.sh \
  | bash -s -- --ntfy <your-topic> --host-label <ssh-host-alias>
```

Set `--host-label` to something you will recognise in a notification title, such as the
machine's SSH host alias.

Restart any running Claude Code sessions to pick up the hooks.

### Choosing a transport

[ntfy.sh](https://ntfy.sh) is a free, open-source pub/sub service. There is no signup, no
bot, no webhook: a channel is just a topic name you invent. Anyone who knows the topic can
read it, **so the app generates a long random one** — it is effectively the password.

Discord is slightly more setup and gives you a browsable channel history that doubles as a
catch-up inbox, plus phone push through the Discord app. See
[Discord setup](#alternative-transport-discord).

### Shell-only install (no Mac app)

The senders are plain bash and work without the app. Use `./install.sh --ntfy <topic>`
from a clone if you want the hooks and nothing else, and read the transport's own history
as your inbox.

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

**Click an item to clear it.** There is no jump-to-session: the notification carries only the first eight characters of the session id, and `claude --resume` needs the whole one, so anything a click could open would be the wrong window.

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
MIN_SECONDS=20                  # ignore turns shorter than this
HOST_LABEL="mac"                # machine name shown in messages
NTFY_SERVER="https://ntfy.sh"   # self-hosted ntfy instance
```

These are sender-side only. Everything the Mac surface does (poll interval, sound, expiry,
idle threshold) lives in the app's own Settings, and the app writes the keys above so the
two can never disagree.

Runtime state lives in `~/.agent-inbox/`: `bin/notify.sh` (unpacked from the app), transport config for the senders (`ntfy-topic`, `webhook-url`, `channel-id`, `guild-id`), `state/<session>.start` (turn timers), `presence` (seconds clocked at the keyboard), and `items.json` (the inbox).

## Updates

The app checks for updates once a day and installs them itself
([Sparkle](https://sparkle-project.org), EdDSA-signed). Turn it off in
**Settings → Updates**, or check on demand from the menu.

Installed with Homebrew? `brew upgrade --cask agent-inbox` works too; either path is fine.

## Requirements

- **Senders** (any OS Claude Code runs on): `bash`, `jq`, `curl`
- **Mac app**: macOS 14 or newer. Nothing else.

## How it works

The app installs three hooks into `~/.claude/settings.json` (idempotent, and it backs the
file up first). On `Stop` and `Notification`, `notify.sh` reads the session transcript,
extracts the context lines, and posts to your transport. The Mac app polls that transport,
raises a native notification, and keeps the item in the menubar inbox until you read it or
until it ages out.

`notify.sh` ships inside the app bundle and is unpacked to `~/.agent-inbox/bin/notify.sh`,
so the hooks keep working when the app is moved, updated, or quit. Secrets the app owns
(bot token, webhook URL) live in the login Keychain rather than on disk; the sender-side
settings stay mirrored into `~/.agent-inbox/config` because the hooks are still bash.

Uninstall: **Settings → Machines → Remove** takes the hooks back out (the original file is
kept at `~/.claude/settings.json.bak.agent-inbox`), then quit the app, drag it to the
Trash, and `rm -rf ~/.agent-inbox/`.

### Upgrading from the shell-only watcher

The app adopts an existing `~/.agent-inbox/` install on first launch: same transport, same
host label, same settings, nothing to retype. Your previous `config` is kept at
`config.bak.agent-inbox`. Then retire the old surface:

```bash
launchctl unload ~/Library/LaunchAgents/com.agent-inbox.watcher.plist
rm ~/Library/LaunchAgents/com.agent-inbox.watcher.plist
rm "$(defaults read com.ameba.SwiftBar PluginDirectory)/agent-inbox.5s.sh"   # plugin symlink
```

Installing hooks from the app replaces any hook pointing at an older `notify.sh`, so you
never get two copies of every event.

## Roadmap

Collapsing (a ✅ retiring an earlier 🖐️ from the same session), and cloud/remote agents in
the same inbox.

## License

MIT
