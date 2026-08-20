#!/usr/bin/env bash
# Build Agent Inbox.app from source.
#
#   ./build.sh                 universal release build, ad-hoc signed
#   ./build.sh --debug         faster, host architecture only
#
# Signing:
#   SIGN_IDENTITY="Developer ID Application: You (TEAMID)" ./build.sh
# Without one the app is ad-hoc signed, which is enough to run it yourself.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(pwd)"
REPO="$(cd .. && pwd)"

CONFIG=release
ARCH_ARGS=(--arch arm64 --arch x86_64)
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug; ARCH_ARGS=() ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

VERSION="$(cat VERSION)"

# Sparkle decides whether an update exists by comparing CFBundleVersion, so it
# has to increase with every release and must not depend on the environment.
# It used to be `git rev-list --count HEAD`, which is 1 on CI because
# actions/checkout does a depth-1 clone: every release shipped build 1, so no
# installed copy could ever see a newer one. Deriving it from VERSION makes it
# a pure function of the release, identical locally and in CI.
BUILD_NUMBER="$(
  IFS=. read -r major minor patch <<EOF
$VERSION
EOF
  printf '%d' $(( ${major:-0} * 1000000 + ${minor:-0} * 1000 + ${patch:-0} ))
)"
APP="$ROOT/build/Agent Inbox.app"
CONTENTS="$APP/Contents"

echo "==> Building AgentInbox ($CONFIG, v$VERSION build $BUILD_NUMBER)"
RPATH=(-Xlinker -rpath -Xlinker @executable_path/../Frameworks)
swift build -c "$CONFIG" "${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}" "${RPATH[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}" --show-bin-path)/AgentInbox"
[ -f "$BIN" ] || { echo "binary not found at $BIN" >&2; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/AgentInbox"

# The icon is generated from source so no binary asset is committed.
if [ ! -f Resources/AppIcon.icns ] || [ Scripts/make-icon.swift -nt Resources/AppIcon.icns ]; then
  echo "==> Rendering app icon"
  ICONSET="$(mktemp -d)/AgentInbox.iconset"
  swift Scripts/make-icon.swift "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

# notify.sh ships inside the app. That is what removes "clone the repo first"
# from setup: the app unpacks it to ~/.agent-inbox/bin/ and points the hooks
# there, so the hooks survive the app being moved or updated.
cp "$REPO/notify.sh" "$CONTENTS/Resources/notify.sh"
chmod +x "$CONTENTS/Resources/notify.sh"

# Sparkle ships as an xcframework in the SPM artifact cache. Take the
# universal macOS slice so a universal app stays universal.
SPARKLE_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE_SRC" ] || { echo "Sparkle.framework not found at $SPARKLE_SRC" >&2; exit 1; }
mkdir -p "$CONTENTS/Frameworks"
# -R preserves the version symlinks the framework needs at runtime.
cp -R "$SPARKLE_SRC" "$CONTENTS/Frameworks/Sparkle.framework"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
  Resources/Info.plist > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> Signing"
IDENTITY="${SIGN_IDENTITY:--}"
# Notarization requires a hardened runtime AND a secure timestamp from Apple.
# An ad-hoc signature cannot carry a timestamp, so only ask for one when
# signing with a real identity.
if [ "$IDENTITY" = "-" ]; then
  TIMESTAMP=--timestamp=none
  # See the comment in the dev entitlements: an ad-hoc signature has no Team
  # ID, so library validation would refuse to load Sparkle.framework.
  ENTITLEMENTS=Resources/AgentInbox-dev.entitlements
else
  TIMESTAMP=--timestamp
  ENTITLEMENTS=Resources/AgentInbox.entitlements
fi
# Signing runs inner-out. `--deep` is deprecated and signs nested code with
# the wrong identity and no entitlements, which notarization rejects.
SPARKLE="$CONTENTS/Frameworks/Sparkle.framework/Versions/B"
for nested in \
  "$SPARKLE/XPCServices/Downloader.xpc" \
  "$SPARKLE/XPCServices/Installer.xpc" \
  "$SPARKLE/Updater.app" \
  "$SPARKLE/Autoupdate"
do
  [ -e "$nested" ] || continue
  codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$nested"
done
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" \
  "$CONTENTS/Frameworks/Sparkle.framework"
codesign --force --options runtime "$TIMESTAMP" \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "Built: $APP"
if [ "$IDENTITY" = "-" ]; then
  echo "Ad-hoc signed. Fine for running locally; use SIGN_IDENTITY to distribute."
fi
