# Agent Inbox

**Native Mac notifications for every Claude Code session that finishes or needs you, across all your machines.**

If you run several Claude Code sessions in parallel, some local and some over SSH on a dev
box, the bottleneck isn't the agents. It's remembering who finished what, and who is sitting
blocked on a permission prompt. Agent Inbox turns that around: sessions interrupt *you*.

- 🖐️ **Needs you.** An agent hit a permission prompt, or ended its turn on a question.
- ✅ **Finished.** A turn completed, with how long it took and the agent's closing words.
- 🧵 **Context on every message.** What the conversation is about and what you last asked,
  so a ping from a two-day-old session still rings the right bell.
- **One row per conversation.** A newer message retires the older ones from the same
  session, so the list says where each conversation is rather than every step it took.
- **Typing clears it.** Start writing in a conversation and its row goes on its own. You
  are already there; it has nothing left to tell you.
- **A sticky menubar inbox.** A `🖐️2 ✅3` badge that stays until you mark it read. Go for
  coffee, come back, see who's waiting.

A native menubar app on the Mac, plain bash on every machine that sends. No server to run
and no account required.

```
senders (Claude Code hooks)         transport              surface (your Mac)
───────────────────────────   ────────────────────   ─────────────────────────
laptop sessions   ─ notify.sh ─┐   ntfy.sh topic    ┌─ native notifications
dev-box sessions  ─ notify.sh ─┼─→      or         ─┤
any other machine ─ notify.sh ─┘   Discord channel  └─ menubar inbox
```

The **transport** is just the channel your machines post to and your Mac reads from. There
is no Agent Inbox server; the transport is somebody else's, and you pick which.

## Install

You need Claude Code already working, and macOS 14 or newer for the app.

### 1. Your Mac

```bash
brew install --cask ideaplaces/tap/agent-inbox
```

Or do the whole thing, install and configure and hooks and login item, in one command:

```bash
curl -fsSL https://raw.githubusercontent.com/Ideaplaces/agent-inbox/main/setup-mac.sh \
  | bash -s -- --ntfy <topic>
```

That drives the same code the setup window does, through the app's CLI flags, so a new
machine needs no clicking. It falls back to downloading the release DMG when Homebrew is
not installed. Teams on Azure Key Vault can use `--keyvault <name>` instead and skip
handling secrets entirely.

Or download the latest `.dmg` from
[Releases](https://github.com/Ideaplaces/agent-inbox/releases) and drag it to Applications.
Either way it is signed and notarized, so it opens without a Gatekeeper warning and updates
itself from then on.

Open it. A setup window appears and does three things:

1. **Picks a transport.** It defaults to ntfy and generates a private topic for you, so
   there is nothing to decide or sign up for.
2. **Wires up this Mac**, by adding three hooks to `~/.claude/settings.json`. It backs the
   file up first and leaves everything else in it alone.
3. **Gives you a one-line command** for your other machines, with a copy button.

Then restart any Claude Code sessions that were already running, so they pick up the hooks.

That is the whole install. Nothing to clone.

### 2. Your other machines

Run the command the app gave you on any other machine where Claude Code runs, including a
dev box you only reach over SSH. It looks like this:

```bash
curl -fsSL https://raw.githubusercontent.com/Ideaplaces/agent-inbox/main/install-remote.sh \
  | bash -s -- --ntfy <your-topic> --host-label <name-for-this-machine>
```

It needs `bash`, `curl`, and `jq`, and nothing else. No login, because the topic itself is
the credential.

`--host-label` is how you tell machines apart in a notification title, so use something you
will recognise. The machine's SSH host alias is the natural choice.

Restart any running Claude Code sessions there too.

> **Give each person their own transport.** Message bodies carry snippets of your prompts
> and Claude's replies. If two people share a topic or a webhook, they each read the
> other's sessions, in both directions.

## Choosing a transport

**ntfy is the default, and you can skip this section.**

[ntfy.sh](https://ntfy.sh) is a free, open-source pub/sub service. There is no signup, no
bot and no webhook: a channel is just a topic name. Anyone who knows the topic can read it,
so the topic is effectively the password, which is why the app generates a long random one
rather than letting you invent a short one. Keep it private.

What ntfy does not give you is history. The public server caches messages for about 12
hours, so the menubar inbox is your record, not the feed.

[Self-hosting ntfy](https://docs.ntfy.sh/install/) changes both of those. Set `NTFY_SERVER`
to your instance, keep as much history as you want, and if it runs `auth-default-access:
deny-all`, set a token so the topic name is no longer the only thing protecting your
messages. The app takes one in **Settings**, or with
`--configure --transport ntfy --topic <t> --server <url> --token <tk>`. It is stored in the
Keychain and mirrored to `~/.agent-inbox/ntfy-token` for the bash senders. Leave it empty
for ntfy.sh, which has no accounts.

Choose **Discord** when you want a durable, browsable archive of every session, plus phone
push through an app you probably already run. It costs a bot and a private channel to set
up. See [Setting up Discord](#setting-up-discord).

## What a notification looks like

```
🖐️ my-app @ devbox
🧵 Refactor the checkout flow to use the new payments SDK   <- conversation summary
🗣 ok now handle the refund path too                        <- your latest message
Claude needs your permission to use Bash                    <- why it pinged
❯ Should I run the migration against staging first?         <- what it's waiting on
```

Three hooks produce these:

| Hook event | Meaning | What you get |
|------------|---------|--------------|
| `UserPromptSubmit` | You handed work to the agent | Nothing. It just records a start time |
| `Stop` | The agent finished its turn | **✅** with the duration and its closing words. Turns shorter than `MIN_SECONDS` (45s by default) are dropped, so quick back-and-forth doesn't spam you |
| `Notification` | The agent needs permission, or has gone idle | **🖐️** with the reason and what it just asked. A permission prompt always reports. The idle timer fires 60s after *every* turn, so it only reports when the agent's closing line was a question; otherwise the ✅ already said it |

**Clicking an item clears it.** There is deliberately no jump-to-session: a notification
carries only the first eight characters of the session id, and `claude --resume` needs the
whole one, so anything a click could open would be the wrong window.

**Items expire on keyboard time, not wall time.** An item clears after you have actually
been at the Mac for a while (five minutes by default, in **Settings → Inbox**), so while you
work the list stays short instead of piling into noise. The clock stops when you step away,
so a coffee-break backlog is still waiting when you get back, and only starts draining once
you are. Set it to `Never` to keep everything until you hit Mark All Read.

## Choosing which conversations report

By default every conversation reports. Twenty sessions open and one you actually
care about is a different problem, so a conversation can be tagged from inside
itself. Type any of these anywhere in a message:

| You type or say | Effect |
|---|---|
| `#notify`, `#inbox`, `#watch`, `#agent-inbox`, or "watch this", "notify me" | This conversation reports |
| `#mute`, or "stop notifying" | This conversation goes quiet |

**The spoken forms are there because dictation cannot produce a `#`.** Saying
"hashtag notify" does not become `#notify` in any dictation tool worth using, so
a tag you can only type is a tag a voice user cannot reach. "Watch this one" is
easy to say and works the same way.

The most recent tag wins, so you can flip a conversation on and off as often as
you like, and it works on a conversation that is already running. Case does not
matter. Nothing else to remember: no session ids, no separate command.

**The tags are yours to choose.** Change them in **Settings → Conversations**.
Separate several with commas, which is what lets a tag be a phrase with spaces in
it. Without a comma they are separated by whitespace, so `#a #b` still means two
tags. Emptying the watch tags restores the defaults rather than leaving a silence
nothing could escape.

**Settings → Conversations → Report** switches the default:

- **Every conversation.** Everything reports, and `#mute` silences the noisy one.
- **Only tagged conversations.** Silence until you tag one. This is the setting
  for "I have twenty open and want one of them."

The mode is per machine, so a dev box can stay quiet while your laptop reports
everything.

It costs nothing to check. The hook that fires when you submit a prompt is handed
the text you typed, so the tag is read from that and the answer is remembered per
session. A transcript can be tens of megabytes and is never opened for this.

The match is a plain substring, so a tag inside pasted code counts too. That is a
deliberate choice: nobody is harmed by a conversation they did not mean to watch,
and the alternative is parsing that gets clever and then gets it wrong.

## Your conversation content travels through the transport

Notification bodies include snippets of your prompts and Claude's replies, plus repo names
and working directory paths. So:

- **ntfy:** treat the generated topic like a password. Anyone who has it can read your
  messages. Self-host if that isn't good enough, and add a token so the topic name grants
  nothing on its own.
- **Discord:** use a private channel, not one other people are in.
- Either way, think twice if you work on sensitive codebases.

## Updates

The app checks once a day and installs updates itself
([Sparkle](https://sparkle-project.org), EdDSA-signed, so it only installs a build signed
with our key). Turn it off in **Settings → Updates**, or check on demand from the menu.

Installed with Homebrew? `brew upgrade --cask agent-inbox` works too. Either path is fine.

## Setting up Discord

Everything below is optional. ntfy needs none of it.

1. Create a Discord bot in the [developer portal](https://discord.com/developers/applications)
   and invite it to your server with permission to manage channels and webhooks.
2. Clone this repo and provision a private channel plus its webhook:
   ```bash
   git clone https://github.com/Ideaplaces/agent-inbox.git && cd agent-inbox
   AGENT_INBOX_GUILD=<server-id> AGENT_INBOX_BOT_TOKEN=<bot-token> \
     ./setup-user.sh <name> <your-discord-user-id>
   ```
   It prints the channel id and webhook URL you need next.
3. **On your Mac**, open **Settings → Transport**, choose Discord, and paste the bot token,
   channel id, server id, and webhook URL. Nothing to run in a terminal.
4. **On every other machine**, use the same one-line installer as before with the webhook
   instead of a topic:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/Ideaplaces/agent-inbox/main/install-remote.sh \
     | bash -s -- --discord-webhook '<webhook-url>' --host-label <name-for-this-machine>
   ```

The bot token is only needed on your Mac, because that is the side that reads messages back.
Sending machines only need the webhook URL, so a dev box can post but cannot read your
history.

**Azure Key Vault users:** set `AGENT_INBOX_VAULT` and use `--keyvault <name>` to keep the
webhook out of your shell history.

## Config

The app owns its own settings, in **Settings**. The only file you might touch is
`~/.agent-inbox/config`, which the bash senders read:

```bash
MIN_SECONDS=45                  # ignore turns shorter than this
WATCH_MODE=all                  # or "tagged": report only tagged conversations
WATCH_TAGS="#notify, #inbox, watch this"   # tags that turn a conversation on
MUTE_TAG="#mute, stop notifying"           # tags that silence one
HOST_LABEL="mac"                # machine name shown in messages
NTFY_SERVER="https://ntfy.sh"   # a self-hosted ntfy instance
```

The ntfy token is deliberately not in here. `config` is written world-readable so a sender
running as another user can read it, so the token lives in `~/.agent-inbox/ntfy-token` at
`0600` instead. Switching transport removes the files belonging to the one you left, because
`notify.sh` posts to whatever it finds: a leftover config is not inert, it keeps sending.

These are sender-side only, and the app writes them itself so the two can never disagree.
Poll interval, sound, expiry and idle threshold are app-side and live in Settings.

Runtime state also lives in `~/.agent-inbox/`: `bin/notify.sh` (unpacked from the app),
the sender's transport config, `state/<session>.start` (turn timers), `presence` (seconds
clocked at the keyboard), and `items.json` (the inbox itself).

## How it works

The app adds three hooks to `~/.claude/settings.json`. It is idempotent, it backs the file
up first, and it leaves your other hooks and settings untouched. On `Stop` and
`Notification`, `notify.sh` reads the session transcript, pulls out the context lines, and
posts to your transport. The Mac app polls that transport, raises a native notification, and
keeps the item in the menubar inbox until you read it or it ages out.

`notify.sh` ships inside the app bundle and is unpacked to `~/.agent-inbox/bin/notify.sh`,
so hooks keep working when the app is moved, updated or quit, and a session that fires a
hook while the app is closed still reaches the transport. Secrets the app owns, the bot
token and webhook URL, live in the login Keychain rather than on disk.

**Requirements:** senders need `bash`, `jq` and `curl` on any OS Claude Code runs on. The
Mac app needs macOS 14 or newer and nothing else.

**Building it yourself:** see [mac/README.md](mac/README.md). It is `./mac/build.sh` plus a
Swift toolchain.

## Uninstall

**Settings → Machines → Remove** takes the hooks back out; the original file is kept at
`~/.claude/settings.json.bak.agent-inbox`. Then quit the app, drag it to the Trash, and
`rm -rf ~/.agent-inbox/`.

On a sending machine, restore the backup the installer left and remove the state:

```bash
mv ~/.claude/settings.json.bak.agent-inbox ~/.claude/settings.json
rm -rf ~/.agent-inbox
```

## Without the Mac app

The senders are plain bash and work on their own, so you can skip the app entirely and read
the transport's history as your inbox. Clone the repo and run
`./install.sh --ntfy <topic>` for the hooks and nothing else.

`install-mac-watcher.sh`, `watch-mac.sh` and `swiftbar-plugin/` are the previous Mac
surface, kept for anyone still running it. **Do not run them alongside the app**, or every
event arrives twice. If you are upgrading from that setup, the app adopts your existing
`~/.agent-inbox/` config on first launch (same transport, same host label, nothing to
retype; your old `config` is kept as `config.bak.agent-inbox`). Then retire the old one:

```bash
launchctl unload ~/Library/LaunchAgents/com.agent-inbox.watcher.plist
rm ~/Library/LaunchAgents/com.agent-inbox.watcher.plist
rm "$(defaults read com.ameba.SwiftBar PluginDirectory)/agent-inbox.5s.sh"
```

Installing hooks from the app replaces any hook pointing at an older `notify.sh`, so you
never end up with two copies of every event.

## Roadmap

Cloud and remote agents in the same inbox.

## License

MIT
