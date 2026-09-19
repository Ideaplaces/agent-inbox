#!/usr/bin/env bash
# Notice when the build machine's toolchain changes under the project.
#
#   ./check-toolchain.sh --check    fail if Xcode or the SDK differs from TOOLCHAIN
#   ./check-toolchain.sh --write    record the current ones, after you have looked
#
# The Mac that builds this app updates Xcode on its own, and nothing in the
# repo changes when it does. 0.1.31 and 0.1.32 came from the same build script
# a day apart; Xcode 27 had arrived in between, its SwiftPM stamped binaries
# with the wrong SDK version, and three releases shipped a menu that floated
# below the menubar. Builds passed, tests passed, screenshots matched. It was
# found from a user's screenshot, weeks later.
#
# A specific check now covers that one symptom. This covers the cause: a
# toolchain change turns CI red on the day it happens, Discord says so, and a
# person looks before the next release rather than after the next three.
#
# When this fails, that is the whole procedure:
#   1. cd mac && ./build.sh && ./package-dmg.sh && ./verify-dmg.sh build/*.dmg
#   2. ./screenshots.sh --check   (new fonts or SDK can move pixels; --write if so)
#   3. run the built app and open the menu once, with your eyes
#   4. ./check-toolchain.sh --write, and commit TOOLCHAIN with what you found
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
FILE="TOOLCHAIN"

current() {
  printf 'xcode=%s\n' "$(xcodebuild -version | awk 'NR==1 {print $2}')"
  printf 'xcode_build=%s\n' "$(xcodebuild -version | awk 'NR==2 {print $3}')"
  printf 'macos_sdk=%s\n' "$(xcrun --sdk macosx --show-sdk-version)"
}

case "${1:-}" in
  --write)
    current > "$FILE"
    echo "recorded:"; cat "$FILE"
    ;;
  --check)
    [ -f "$FILE" ] || { echo "mac/$FILE is missing; run check-toolchain.sh --write" >&2; exit 1; }
    if diff <(current) "$FILE" >/dev/null; then
      echo "toolchain unchanged: $(tr '\n' ' ' < "$FILE")"
    else
      echo "The build machine's toolchain changed." >&2
      echo "  recorded: $(tr '\n' ' ' < "$FILE")" >&2
      echo "  now:      $(current | tr '\n' ' ')" >&2
      echo "Nothing is known to be broken. Follow the four steps at the top of" >&2
      echo "mac/check-toolchain.sh, then commit the new mac/TOOLCHAIN." >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: check-toolchain.sh --check | --write" >&2
    exit 2
    ;;
esac
