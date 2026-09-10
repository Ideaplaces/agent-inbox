# Agent Inbox: working notes

The Mac app is in `mac/`, the senders are bash at the repo root. `mac/README.md`
has the architecture and the design decisions; this file is what someone
changing the code needs to know.

Release credentials, the signing certificate and the machine that builds the
DMG are deliberately not here. They are IdeaPlaces-internal and this repository
is public.

## Local development

```bash
cd mac
swift test          # no network, no side effects
./build.sh --debug  # ad-hoc signed, host architecture, fine for running yourself
SIGN_IDENTITY="Developer ID Application: ..." ./build.sh
```

Copying a local build over `/Applications` replaces the released one, so brew's
recorded version will disagree with what is installed until the next upgrade.
Harmless, but it explains the mismatch.

The senders are testable without a transport:

```bash
./test-notify.sh    # runs notify.sh against a throwaway HOME, prints instead of posting
```

## Gotchas already paid for

Each of these shipped a release that looked healthy and was not. The full
write-up, including the fixes, is at
docs.ideaplaces.com/devops/macos-app-signing.

- **The build number has to rise.** Sparkle compares `CFBundleVersion`, not the
  marketing version. It came from `git rev-list --count HEAD`, which is `1` on CI
  because checkout clones to depth 1, so every release shipped build 1 and no
  update was ever offered. Now derived from the version.
- **`--timestamp=none` fails notarization.** Ad-hoc signing requires it and Apple
  rejects it, so branch on the identity.
- **Staple the app, not only the DMG.** A ticket on the image does not travel with
  the app into `/Applications`, leaving a Mac that is offline at first launch with
  nothing to fall back on.
- **`--deep` is wrong once a framework is embedded.** Sign inner-out: Sparkle's
  XPC services, `Updater.app`, `Autoupdate`, the framework, then the app.
- **Library validation needs matching Team IDs.** An ad-hoc signature has none, so
  a local build dies loading Sparkle. Ad-hoc builds use a separate entitlements
  file that relaxes it; never ship that file.
- **`hdiutil create -srcfolder` needs a writable mount.** Managed Macs and CI
  runners force disk images read-only. Use `makehybrid`.
- **Apple's timestamp server fails under load.** `A timestamp was expected but
  was not found.` broke the v0.1.5 release on a Sparkle XPC service. The
  timestamp is mandatory for notarization, so signing retries with backoff
  rather than failing the release.
- **Build against the SDK the app will run on.** 0.1.8 was built on the hosted
  `macos-14` image, so it links against the macOS 14.5 SDK. On macOS 26 that
  binary grows its `MenuBarExtra` window and never shrinks it again: the window
  stays at the tallest list of the session (measured at 560x472) while the
  content draws its real height, and SwiftUI centres the content in the
  leftover space. The result is a menu floating ~140pt below the menubar with
  dead margin above and below, which reads as a padding bug and is not one. The
  same source built with the macOS 26 SDK goes 652 -> 157 across the same
  shrink. Check with `vtool -arch arm64 -show-build <binary> | grep sdk` before
  chasing a layout problem that only appears on one Mac.
- **A Focus profile silences notifications and nothing in the API says so.**
  `UNUserNotificationCenter` reported `authorized`, `alert: enabled`,
  `sound: enabled`; audio output was fine; and `"Pop"`, `"Pop.aiff"` and
  `.default` were all silent. A Focus mode the app cannot see was filtering it.
  Before chasing a sound name or a permission, ask whether Focus is on: the app
  has no way to detect it and `add()` reports success either way.
- **The hook runs `~/.agent-inbox/bin/notify.sh`, not your checkout.** The app
  unpacks it from the bundle at launch, so a fix in the repo does nothing until
  a build carrying it is installed. A local build made before the fix will
  happily overwrite the good copy. Check with `grep` against the installed file,
  not the one you edited.
- **A file left by a transport you stopped using keeps sending.** `notify.sh`
  posts to whatever it finds in `~/.agent-inbox/`, so switching the app from
  Discord to ntfy left every session publishing to both for days with nothing
  to show it. The writer now retires the other transport's files.
- **The DMG window comes from a committed `.DS_Store`.** Without one, Finder
  opens the image at whatever size and icon scale it last used, which is the
  cramped default window. The usual way to make one is to mount the image
  read-write and drive Finder over AppleScript, and this project cannot: that
  is the same read-only-mount problem that made `create -srcfolder` unusable.
  `mac/dmg/make-ds-store.py` writes the file directly, with no mount and no
  GUI, and `makehybrid` does carry dotfiles into the image. Re-run it only when
  the layout changes, and note that the names in it must match the staged files
  exactly or Finder silently falls back to automatic positions.
- **Finder drops a view-options dictionary it does not recognise, whole.** The
  0.1.24 image asked for 128pt icons and got Finder's default 64: the window
  settings in `bwsp` applied while every setting in `icvp` was discarded, with
  no error and nothing in a log. The file carried two keys Finder never writes
  (`scrollPositionX`/`scrollPositionY`, plus a stray `ICVO`) and was missing
  three it always writes (`backgroundColorRed`/`Green`/`Blue`). Match the key
  set of a `.DS_Store` Finder itself produced, which means pulling one out of a
  shipping DMG and diffing against it.
- **The background picture needs the `pBBk` bookmark, not only the alias.**
  `backgroundImageAlias` inside `icvp` is the older half and Finder does not
  resolve it on its own. Both are written now.
- **AppleScript cannot tell you whether the background applied.** `background
  picture of icon view options` reports `NONE` for images that certainly have
  one, checked against a third-party DMG as a control before trusting the
  reading. `icon size` and the window bounds do read back correctly, so verify
  what can be verified and have a person look at the rest.
- **The wire has a contract now, and two ways a message can reach the parser.**
  `notify.sh` appends a versioned JSON line after the human lines and the old
  footer. `Transport.splitFooter` peels the last body line only if it looks
  like a footer, so normally the JSON stays in the body and the footer arrives
  inside it; but if any contract string contains ` · /`, `splitFooter` peels the
  JSON into `message.footer` instead. `MessageParser` checks both places.
  Anyone rewriting `splitFooter` needs to keep both arrangements working, and
  `MessageParser.peelFooter` duplicates its two conditions on purpose so the
  model layer does not import the transport: change one, change both.
- **A contract with a null or unknown `kind` falls back whole.** Half-applying
  a contract is worse than ignoring it, so the parser drops to the emoji
  heuristics for the entire message rather than filling what it can.
- **`closing_words` never contains a newline.** Line ends are sentence ends by
  design. A test asserting a newline survives through `.closing` will fail on
  the reduction, not on jq.
- **`HOST_LABEL` in the environment is ignored.** `notify.sh` assigns
  `hostname -s` unconditionally before sourcing config, so only
  `~/.agent-inbox/config` can set it. `HOST_LABEL=x ./notify.sh` does nothing.
- **The dry-run output has no `footer:` line any more.** The footer is the
  second-to-last body line and the JSON contract the last. `tail -1` of a dry
  run is the contract.
- **Backoff after a failure starts at 2s, not 1s.** `consecutiveFailures` is
  incremented before the sleep, so the ladder after failures is 2, 4, 8, 16,
  32, 60. `backoff(0)`, one second, is the wait after a healthy stream closes.
  Pinned in `ReceiverTests`; change the loop and the test together.
- **The receiver's watchdog ends the connection; it used to only flag it.** The
  first streaming build set a flag at ten seconds but stayed inside the
  `for try await` until URLSession's 120s idle timeout threw, so the poll
  fallback began after two minutes, not ten seconds. Nothing caught it because
  nothing could: the loop called `Task.sleep` directly. Making time injectable
  (`Sleeper`) is what surfaced it. Stream and watchdog are now siblings in a
  task group and the first to finish decides.
- **`receiver.restart()` no longer restarts housekeeping.** Reconnect and topic
  changes cycle the connection only; presence and expiry keep their own clock.
- **In receiver tests, settle on the last effect in the chain, not the first.**
  `settle(until:)` returns when its condition holds; state set one hop later
  may not be there yet. And two sleeps woken by one `advance` resume in
  deadline order, but the main actor does not promise to run them in that
  order, so never assert cross-task ordering off a single advance.
- **Never use `UserDefaults(suiteName:)` in a test.** It writes a real plist
  into `~/Library/Preferences`, and cfprefsd rewrites it after the process has
  exited, so `removePersistentDomain` in `tearDown` does not stick. Two tests
  had left 826 of them on the maintainer's Mac before anyone looked. Use
  `MemoryDefaults` from `IsolatedSettings.swift`, and build models through
  `IsolatedSettings.model()`, which is the one way a test gets an app model
  that touches nothing real.
- **Adding a setting is two places.** A property on `SettingsValues` and a
  line in its hand-written `init(from:)`. Forget the second and the field
  decodes as its default forever, silently, because the decoder is deliberately
  lenient so an older snapshot never fails to load.
- **The gate for "no singletons" is `static let shared`, not `.shared`.**
  `grep -rn "\.shared" mac/Sources` will always find Apple's own
  (`NSWorkspace.shared`, `URLSession.shared`). The one that means something is
  `grep -rn "static let shared\|static var shared" mac/Sources`, which must
  print nothing.
- **Sender config writes are change-gated now.** A setter used to rewrite
  `~/.agent-inbox/config` unconditionally; now `sync()` runs only when a
  sender-visible field actually changed. `AppModel.start()` still syncs once
  unconditionally, so a fresh launch always leaves the file current.
- **The delegate gets the model from the App, not from a global.**
  `AgentInboxApp.init` builds the model and sets `delegate.model` on the
  adaptor, which has already constructed the delegate by then; verified with a
  throwaway package rather than assumed. The optional is guarded with a
  precondition, so a future refactor that reorders this fails at launch
  loudly, which is the right failure.
- **The senders and the app are checked against each other on every push.**
  `fixtures/wire/` holds the sender's real dry-run output for seven scenarios,
  regenerated by `fixtures/wire/regenerate.sh` with every varying input pinned;
  `test-notify.sh` fails if the committed files drift, and `WireFixtureTests`
  decodes every one through `splitFooter` then the parser and asserts
  `.contract`. A new scenario is three edits: `regenerate.sh`, run it, and the
  `expected` list in the Swift test, which asserts the directory holds exactly
  that set so a forgotten entry fails rather than being skipped.
- **Tests source `notify.sh`, they do not cut functions out of it.**
  `AGENT_INBOX_SOURCE_ONLY=1 source notify.sh` returns before the stdin read
  and the dispatch. `AGENT_INBOX_NOW` pins "now" for the same reason. Both are
  environment-only seams; config cannot set them. Under a normal run the
  top-level `return` is a silent no-op, so the seam only means anything when
  sourced.
- **Tags inside code are ignored.** An agent's report quoting `` `#mute` ``
  muted the maintainer's session for hours. `strip_code` drops fenced blocks
  and inline spans before matching; an unclosed fence swallows the rest of the
  prompt on purpose, biased toward not matching. Worth knowing when someone
  reports "my #notify did nothing".
- **The end-to-end test is the one that catches sender-to-app bugs.**
  `EndToEndTests` runs the real `notify.sh` as a subprocess against
  `FakeNtfyServer` on 127.0.0.1 and asserts a row in the store. It would have
  caught the `"$BODY💬"` expansion bug; the test was proven by putting that bug
  back and watching it fail. It skips only when `jq` is missing.
- **Never build an `AppModel` in a test without `IsolatedSettings.model()`.**
  `UNUserNotificationCenter.current()` aborts the whole test process in a
  bundle-less runner. `IsolatedSettings` passes a `RecordingPoster`; a bare
  `AppModel(settings:defaults:)` that delivers an item takes every test down
  with it.
- **In `FakeNtfyServer`, a dropped stream is a clean close on purpose.** It
  writes the terminating chunk before cancelling, which is what makes
  `stream()` finish without throwing and the receiver reconnect on the 1s
  path. Cancelling without it is the "killed process" case: URLSession throws
  `-1005`, the receiver counts a failure and backs off 2s. Both are real ntfy
  behaviours; the tests exercise the first.
- **`settle()` cannot wait across a socket.** It yields a fixed number of times,
  which is microseconds. Anything waiting on URLSession or a subprocess uses
  `eventually(within:)`, a real-time deadline poll.
- **The installers refused nothing until they had tests.** Both reported success
  over a corrupt `settings.json` because `set -e` does not fire inside an `&&`
  list; `install.sh` wrote the hook path unquoted, so a checkout under a
  directory with a space produced hooks that exit 127 on every turn. Fifty-one
  checks in `test-install.sh` now, run in CI on Ubuntu and verified on macOS
  bash 3.2. Any change to how hooks are written must keep
  `HookInstaller.swift` and both shell installers in agreement; the test's
  `app_shape_ok` asserts it.
- **The README screenshots are generated, checked in CI, and re-committed by
  every release.** `mac/screenshots.sh --write` regenerates `docs/*.png` from
  the views with every varying input pinned; `--check` renders into a temp
  directory and fails the push if `docs/` differs or the README links an image
  nothing generates. It runs only on the self-hosted Mac: the images are
  byte-exact to that machine's SDK and fonts. The version in the pictures is a
  fixed `1.0.0` on purpose, because the release runner rewrites `VERSION` from
  the tag while the file in git stays behind, and a picture tracking either
  would fail the check on the first push after every release.
- **A settings capture must be sized to the view's own fitting height.**
  Forcing a taller frame makes the scroll view fill the slack by scrolling and
  the picture comes out mid-page with the header and tabs cut off.
- **`IsolatedSettings` redirects `HookInstaller.settingsURL` too.** It did not
  for a while, so an "isolated" model read this Mac's real
  `~/.claude/settings.json` and the Machines screenshot carried a warning about
  the maintainer's own hooks. Two statics are redirected into the scratch
  directory; a third one would be a test reading something real again.
- **`mac/verify-dmg.sh` reads a built image back the way Finder and Sparkle
  will**, and runs in CI after packaging and in the release before publishing.
  A probe that pipes its output through `tail` loses the exit code; call it
  bare. Stray `/Volumes/Agent Inbox N` mounts on a dev Mac are from hand
  probing, not from it: it detaches in a trap on every path.
- **Local shellcheck says nothing about CI's.** Ubuntu's runner ships 0.9.0,
  a current Mac 0.11. SC2120 (an argument nothing passes) exists only in the
  older one and turned every push red for a week while the Mac said clean.
  chipdev has 0.8.0, which is the stricter check: run a script through it
  before trusting a green local run.
- **Test the binary you think you are testing.** A `--configure` flag appeared to
  hang through several rounds of debugging because `/Applications` held the
  released build, which predated the flag.

## Keep README.md current

**Anything a user would want to know goes into `README.md` in the same change that
introduces it.** Not afterwards, not in a follow-up pass: the README is the only
description of this thing most people will ever read, and a feature nobody knows
about was not worth building.

That means a new behaviour, a changed one, a new setting or config file, a new
transport, a new flag, a changed default, or a rule that decides whether a
notification fires at all. It does not mean refactors, internal fixes, or
anything invisible from outside.

Two failure modes to watch for, both of which had happened by the time this was
written:

- **The Roadmap section describing something already shipped.** Collapsing rows
  sat there while the feature was live.
- **A behaviour table that is now a lie.** The hook table said the idle timer
  produces a 🖐️, months after it stopped doing so unconditionally.

When a change alters what a notification means, the tables in "What a
notification looks like" are the first thing to reread, not the last.

## Conventions

- Feature branches off `main`, PRs into `main`. This repo has no `develop`.
- Every user-visible change updates `README.md` in the same PR. See above.
- No AI attribution in commits.
- The senders must stay POSIX-ish bash: they run on Linux dev boxes, not only macOS.
- `notify.sh` must never block or fail a Claude Code session. Every exit path is
  0 and every network call has a short timeout.
