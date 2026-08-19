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
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="$ROOT/build/Agent Inbox.app"
CONTENTS="$APP/Contents"

echo "==> Building AgentInbox ($CONFIG, v$VERSION build $BUILD_NUMBER)"
swift build -c "$CONFIG" "${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}"
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

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
  Resources/Info.plist > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> Signing"
IDENTITY="${SIGN_IDENTITY:--}"
# Hardened runtime is required for notarization and harmless without it.
codesign --force --deep --options runtime --timestamp=none \
  --entitlements Resources/AgentInbox.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "Built: $APP"
if [ "$IDENTITY" = "-" ]; then
  echo "Ad-hoc signed. Fine for running locally; use SIGN_IDENTITY to distribute."
fi
