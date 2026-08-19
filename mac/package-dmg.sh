#!/usr/bin/env bash
# Build a distributable Agent Inbox DMG.
#
#   ./package-dmg.sh                       unsigned, for local testing
#   SIGN_IDENTITY="Developer ID Application: You (TEAMID)" \
#   NOTARY_PROFILE=agent-inbox ./package-dmg.sh
#
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials agent-inbox \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Without notarization Gatekeeper shows "cannot be opened because the developer
# cannot be verified" on another Mac. Notarize anything you hand to someone.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
VERSION="$(cat VERSION)"
APP="build/Agent Inbox.app"
STAGE="build/dmg"
DMG="build/AgentInbox-$VERSION.dmg"

./build.sh

echo "==> Staging disk image"
rm -rf "$STAGE" "$DMG" build/hybrid.dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# `makehybrid` builds the filesystem directly from a folder, with no mount
# step. `hdiutil create -srcfolder` needs one, and managed Macs and CI runners
# routinely force every disk image to mount read-only, which fails the copy.
echo "==> Building image"
hdiutil makehybrid -hfs -hfs-volume-name "Agent Inbox" \
  -o build/hybrid.dmg "$STAGE" >/dev/null

echo "==> Compressing to $DMG"
hdiutil convert build/hybrid.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f build/hybrid.dmg

if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> Signing disk image"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarizing (this waits on Apple, usually a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> Stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG" || true
else
  echo "==> Skipping notarization (set NOTARY_PROFILE to enable)"
fi

rm -rf "$STAGE"
echo
echo "Built: $DMG"
shasum -a 256 "$DMG"
