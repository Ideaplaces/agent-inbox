# Agent Inbox: working notes

The Mac app lives in `mac/`. The senders are bash at the repo root. Read
`mac/README.md` for the architecture and the design decisions; this file is the
operational half: how to cut a release, and what cannot be done without a human.

## Cutting a release

One step. There is no version file to edit: the workflow takes the version from
the tag and rejects anything that is not `vMAJOR.MINOR.PATCH`.

```bash
git tag -a v0.1.5 -m "Agent Inbox 0.1.5

<what changed>"
git push origin v0.1.5
```

That builds universal, signs with Developer ID, notarizes and staples **both the
app and the DMG**, publishes the GitHub release, and commits `appcast.xml` so
installed copies can see the update. The Homebrew tap bumps itself within 30
minutes.

**Verify the published artifact rather than the green check.** Every failure in
this pipeline has been silent, so a passing workflow is not evidence:

```bash
gh release download v0.1.5 -p "*.dmg"
spctl --assess --type open --context context:primary-signature -vv AgentInbox-0.1.5.dmg
# want: accepted / source=Notarized Developer ID

curl -s https://raw.githubusercontent.com/Ideaplaces/agent-inbox/main/appcast.xml \
  | grep -E "sparkle:version|shortVersionString"
# the build number must be HIGHER than the installed one, or no update is offered
```

## What runs on its own

| Trigger | What happens |
|---|---|
| Any push or PR | Swift tests, universal build, DMG packaging, shellcheck |
| A `v*` tag | Sign, notarize and staple app + DMG, publish release, commit appcast |
| Every 30 min, in `Ideaplaces/homebrew-tap` | The tap bumps its own casks from the latest release |

Both Mac jobs run on a **self-hosted runner**, Chip's MacBook, labelled
`self-hosted, macOS, ARM64, chip-macbook, xcode26` and registered against this
repo. A tag therefore only builds while that machine is awake; until then the
job queues rather than failing. That tradeoff is deliberate, see the SDK note
below.

**The tap updates itself; nothing pushes to it.** A cross-repo push needs a
credential the org cannot issue, so the direction was inverted: a workflow can
always write to its own repository, and reading a public repo's releases needs no
auth. This is a decision, not a gap. Do not "fix" it by adding a token.

## What needs a human

Everything here requires a browser or a GUI. Ask rather than spending time
trying to automate it, and name which one you need.

| What | Why it cannot be scripted |
|---|---|
| A GitHub PAT | No API exists to create one |
| A GitHub App | The manifest flow ends in a browser click |
| Enabling deploy keys | Disabled by org policy; changing it needs `admin:org` |
| Workflow write permissions | Same policy. Not needed anyway, see above |
| Renewing the signing certificate | Xcode → Settings → Accounts → Manage Certificates. Account Holder only, capped at five per team. **Expires 1 February 2027** |
| Exporting that certificate as `.p12` | `security export` is refused by the key's ACL. Keychain Access → My Certificates → Export |
| An App Store Connect API key | Downloadable exactly once, from the browser |
| Full Disk Access grants | System Settings, and the file picker needs ⌘⇧G to reach `/opt` |
| Clicking Check for Updates | The one link in the update chain that cannot be driven headlessly |

## Credentials

Held in Azure Key Vault `kv-ideaplaces` and mirrored to this repo's Actions
secrets. The secret names are already visible in
`.github/workflows/release.yml`; the values are not.

| Key Vault | Actions secret |
|---|---|
| `apple-developer-id-p12-base64` | `MACOS_CERTIFICATE` |
| `apple-developer-id-p12-password` | `MACOS_CERTIFICATE_PASSWORD` |
| `apple-developer-id-sign-identity` | `MACOS_SIGN_IDENTITY` |
| `apple-notary-api-key` | `APPLE_API_KEY` (base64) |
| `apple-notary-key-id` | `APPLE_API_KEY_ID` |
| `apple-notary-issuer-id` | `APPLE_API_ISSUER` |
| `sparkle-eddsa-private-key` | `SPARKLE_PRIVATE_KEY` |
| `sparkle-eddsa-public-key` | in `Info.plist` as `SUPublicEDKey` |

Verify a round-trip before trusting the vault. `az` appends a trailing newline to
text secrets, which is harmless for the `.p8` but makes a naive `diff` report a
difference that is not there.

**Losing the Sparkle private key means no installed copy can ever update again.**
It is the only irrecoverable secret here.

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
- **Test the binary you think you are testing.** A `--configure` flag appeared to
  hang through several rounds of debugging because `/Applications` held the
  released build, which predated the flag.

## Local development

```bash
cd mac
swift test          # 29 checks, no network, no side effects
./build.sh --debug  # ad-hoc signed, host architecture, fine for running yourself
SIGN_IDENTITY="Developer ID Application: IdeaPlaces Inc. (648L7A4BL2)" ./build.sh
```

Copying a local build over `/Applications` replaces the released one, so brew's
recorded version will disagree with what is installed until the next upgrade.
Harmless, but it explains the mismatch.

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
