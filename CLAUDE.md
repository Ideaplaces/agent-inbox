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
