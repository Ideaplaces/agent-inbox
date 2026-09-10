#!/usr/bin/env bash
# Open a built disk image and check it holds what a person will get.
#
#   ./verify-dmg.sh build/AgentInbox-0.1.31.dmg
#
# CI used to build the image and assert nothing about it. Every failure in
# this pipeline has been silent: a layout file that did not stage, a build
# number that never rose, a background the Finder could not find. Each one
# shipped as a healthy-looking DMG. This reads the image back the way Finder
# and Sparkle will, and says so per check.
set -euo pipefail

DMG="${1:?usage: verify-dmg.sh <path.dmg>}"
cd "$(dirname "${BASH_SOURCE[0]}")"
EXPECTED="$(cat VERSION)"

MOUNT="$(mktemp -d)"
cleanup() { hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true; }
trap cleanup EXIT

hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
APP="$MOUNT/Agent Inbox.app"

fail() { echo "FAIL $1" >&2; exit 1; }
ok()   { echo "ok   $1"; }

[ -d "$APP" ] && ok "Agent Inbox.app is on the image" || fail "Agent Inbox.app missing"
[ "$(readlink "$MOUNT/Applications")" = "/Applications" ] \
  && ok "Applications symlink points at /Applications" || fail "Applications symlink wrong or missing"
[ -f "$MOUNT/.DS_Store" ] && ok ".DS_Store (window layout) present" || fail ".DS_Store missing: Finder will open the image at its default size"
[ -f "$MOUNT/.background/background.png" ] \
  && ok "background picture present" || fail "background.png missing: the .DS_Store points at nothing"

PLIST="$APP/Contents/Info.plist"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
[ "$SHORT" = "$EXPECTED" ] && ok "version $SHORT matches VERSION" || fail "version $SHORT but VERSION says $EXPECTED"
# Sparkle compares the build number, which once shipped as 1 on every release
# so no update was ever offered. It is derived from the version now and must
# be well above that.
[ "$BUILD" -gt 1000 ] 2>/dev/null && ok "build number $BUILD rises with the version" || fail "build number is $BUILD; Sparkle will never offer this as an update"

# Never --strict. hdiutil makehybrid stamps Finder info on every file, the
# volume reports it as com.apple.FinderInfo, and --strict rejects it as
# "detritus" on Sparkle's Autoupdate. The shipped, notarized 0.1.30 fails
# --strict for exactly this while spctl accepts it, so strict here would fail
# every release for a reason Apple does not care about. --deep without it is
# what Gatekeeper actually checks.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --verify --deep "$APP" && ok "signature verifies" || fail "signature does not verify"
  # The authority chain prints only at verbose=2; plain -dv omits it. And it is
  # captured first rather than piped into grep -q: under pipefail, grep -q
  # closing the pipe on its first match gives codesign a SIGPIPE on the lines
  # still to come and the whole pipeline reads as failed. Both of those failed
  # this check against the shipped, notarized 0.1.30 before it was right.
  AUTHORITY="$(codesign -dv --verbose=2 "$APP" 2>&1)"
  case "$AUTHORITY" in
    *"Authority=Developer ID Application"*) ok "signed with a Developer ID" ;;
    *) fail "not signed with a Developer ID" ;;
  esac
else
  codesign --verify "$APP" && ok "signature verifies (ad-hoc, local build)" || fail "signature does not verify"
fi

# The unpacked sender rides inside the bundle and becomes ~/.agent-inbox/bin/notify.sh.
NOTIFY="$(find "$APP/Contents/Resources" -name notify.sh | head -1)"
[ -n "$NOTIFY" ] && cmp -s "$NOTIFY" ../notify.sh \
  && ok "bundled notify.sh matches the repo" || fail "bundled notify.sh missing or stale"
