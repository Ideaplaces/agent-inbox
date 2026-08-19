# Agent Inbox.app

The Mac surface: a menubar app that polls your transport, raises native notifications, and
keeps a sticky inbox of every session that finished or needs you. Reading an item is the
whole interaction; clicking it clears it.

It replaces the old three-part Mac setup (a launchd watcher, terminal-notifier, and a
SwiftBar plugin) with one signed app that has its own icon, its own Settings window, and
its own name in Login Items. The senders stay bash, because they have to run on Linux dev
boxes too.

## Build it yourself

Requires macOS 14+ and a Swift 5.9+ toolchain (Xcode or the Command Line Tools).

```bash
./build.sh                 # universal release build -> build/Agent Inbox.app
./build.sh --debug         # host architecture only, faster
swift test                 # 29 tests, no network, no side effects
```

`build.sh` ad-hoc signs the bundle, which is all you need to run it yourself. Drag
`build/Agent Inbox.app` to `/Applications` and open it.

## Ship a DMG

```bash
./package-dmg.sh                                    # unsigned, for local testing

SIGN_IDENTITY="Developer ID Application: You (TEAMID)" \
NOTARY_PROFILE=agent-inbox ./package-dmg.sh         # signed + notarized + stapled
```

Create the notary profile once:

```bash
xcrun notarytool store-credentials agent-inbox \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

Without notarization, Gatekeeper on someone else's Mac refuses to open the app with
"cannot be opened because the developer cannot be verified". Notarize anything you hand to
another person. A **Developer ID Application** certificate is required; the Apple
Distribution certificate Xcode creates by default is for the App Store and will not work
for a DMG.

The image is built with `hdiutil makehybrid` rather than `hdiutil create -srcfolder`,
because the latter needs a scratch mount and managed Macs and CI runners routinely force
every disk image to mount read-only.

## Scriptable setup

Useful for provisioning a machine without clicking through the UI:

```bash
"/Applications/Agent Inbox.app/Contents/MacOS/AgentInbox" --install-hooks
"/Applications/Agent Inbox.app/Contents/MacOS/AgentInbox" --register-login-item
"/Applications/Agent Inbox.app/Contents/MacOS/AgentInbox" --unregister-login-item
```

Each flag performs one action and exits without starting the UI.

## Layout

```
Sources/AgentInbox/
├── AgentInboxApp.swift        MenuBarExtra + Settings scenes
├── AppModel.swift             shared state, notification actions, CLI flags
├── Models/
│   ├── InboxItem.swift        the wire format and its parser
│   └── AppSettings.swift      UserDefaults + Keychain, mirrored to ~/.agent-inbox
├── Store/
│   ├── InboxStore.swift       items, read state, presence-based expiry
│   └── Keychain.swift
├── Transport/                 ntfy and Discord, both stateless
├── Services/
│   ├── Poller.swift           the loop, cursors, connection status
│   ├── Presence.swift         time actually spent at the keyboard
│   ├── HookInstaller.swift    safe edits to ~/.claude/settings.json
│   ├── SenderConfig.swift     the ~/.agent-inbox contract with the bash senders
│   └── Notifier.swift
└── Views/                     menu, welcome, settings
Scripts/make-icon.swift        renders the app icon; no binary asset is committed
```

## Design notes

**The hooks point at `~/.agent-inbox/bin/notify.sh`, not into the app bundle.** The app
unpacks its copy there on launch. Hooks then survive the app being moved, updated, or
quit, and a session that fires a hook while the app is closed still reaches the transport.

**Items expire against keyboard time, not wall time.** `Presence` accumulates only while
you are actually at the Mac. Step away and the inbox stops draining, so a coffee-break
backlog is still waiting when you come back.

**Cursors are keyed by channel.** Switching topic or transport retires the old cursor
instead of replaying somebody else's history.

**Adoption reads before it writes.** Every settings setter mirrors back into
`~/.agent-inbox/`, so taking over an existing bash install has to read the whole directory
into memory first. Getting this wrong destroys the config it is trying to import; there is
a test for it.
