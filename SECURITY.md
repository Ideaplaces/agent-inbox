# Reporting a security issue

Please do not open a public issue for a security problem.

Use **[Report a vulnerability](https://github.com/Ideaplaces/agent-inbox/security/advisories/new)**
on this repository. It is private, only maintainers see it, and it gives us a
place to fix and publish together.

You should get a first reply within a few days. If you hear nothing after a
week, open a normal issue saying only that you are waiting on a security
report, with no detail in it.

## What is worth reporting

This is a menubar app, a bash sender, and a channel between them, so the
interesting parts are:

- **The transport.** Notification bodies carry snippets of your prompts and
  Claude's replies, repo names and working directory paths. Anything that
  discloses those to someone who should not have them.
- **The ntfy token or a Discord webhook leaking.** Both are credentials. They
  live in the Keychain and in `~/.agent-inbox/` at `0600`, never in `config`,
  which is world-readable by design.
- **`notify.sh`.** It runs inside every Claude Code session on every machine you
  install it on. Command injection from a prompt, a repo name, or a transcript
  would be serious.
- **The updater.** Sparkle checks an EdDSA signature against a key baked into
  `Info.plist`. Anything that lets an unsigned or differently-signed build
  install is serious.
- **Hook installation.** The app edits `~/.claude/settings.json`. Anything that
  lets it write something you did not ask for belongs here.

## What is already known, and is a design decision

These are documented in the README rather than defects. Reporting them is
welcome, but they will not be treated as vulnerabilities.

- **On public ntfy.sh, the topic name is the whole secret.** Anyone who learns
  it can read your notifications. The app generates a long random topic for
  exactly this reason, and self-hosting with a token is the answer if that is
  not good enough for you.
- **Notification bodies contain conversation content.** That is the feature.
  Think about it before installing on a machine with sensitive work on it.
- **The senders trust the machine they run on.** Anyone who can write to
  `~/.agent-inbox/` can redirect your notifications. So can anyone who can edit
  your `~/.claude/settings.json`.

## Supported versions

The latest release. The app updates itself, so fixes reach installs through
Sparkle rather than through backports.
