#!/usr/bin/env bash
# Fail unless a binary is stamped with a current SDK, in every architecture.
#
#   ./check-sdk-stamp.sh <path to a Mach-O binary>
#
# macOS picks AppKit and SwiftUI behaviour from the SDK version recorded in
# the binary. A stamp older than the OS it runs on opts the app into old
# behaviour, which for this app means a menubar window that never shrinks.
# Nothing about that is visible in a build log or a test run: the binary
# works, the tests pass, and the menu floats on the user's screen. Three
# releases shipped that way. The stamp is the only place it shows, so the
# stamp is what gets checked: by build.sh on every build, and by
# verify-dmg.sh on the image before a release publishes it.
set -euo pipefail

BIN="${1:?usage: check-sdk-stamp.sh <binary>}"
# The floor: the macOS this build machine runs. A stamp below it means the app
# would get behaviour older than the machine that built it.
HOST_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"

status=0
for arch in $(lipo -archs "$BIN"); do
  sdk="$(vtool -arch "$arch" -show-build "$BIN" | awk '$1 == "sdk" {print $2}')"
  major="${sdk%%.*}"
  if [ -z "$sdk" ] || [ "$major" -lt "$HOST_MAJOR" ]; then
    echo "FAIL $arch is stamped sdk ${sdk:-none}, older than macOS $HOST_MAJOR: the menubar window will float" >&2
    status=1
  else
    echo "ok   $arch stamped sdk $sdk"
  fi
done
exit "$status"
