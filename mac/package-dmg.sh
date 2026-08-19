#!/usr/bin/env bash
# Build a distributable Agent Inbox DMG.
#
#   ./package-dmg.sh                       unsigned, for local testing
#
# Signing:
#   SIGN_IDENTITY="Developer ID Application: You (TEAMID)"
#
# Notarization, whichever set of credentials you have:
#   NOTARY_PROFILE=agent-inbox                       a stored keychain profile
#   NOTARY_KEY=AuthKey.p8 NOTARY_KEY_ID=... NOTARY_ISSUER=...   App Store Connect API key
#   NOTARY_APPLE_ID=you@example.com NOTARY_TEAM_ID=... NOTARY_PASSWORD=...   app-specific password
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

NOTARY_ARGS=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
fi

if [ ${#NOTARY_ARGS[@]} -gt 0 ]; then
  echo "==> Notarizing (this waits on Apple, usually a few minutes)"
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
  echo "==> Stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "==> Gatekeeper assessment"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
else
  echo "==> Skipping notarization (no credentials set; see the header)"
fi

rm -rf "$STAGE"
echo
echo "Built: $DMG"
shasum -a 256 "$DMG"
