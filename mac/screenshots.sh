#!/usr/bin/env bash
# The README screenshots, generated from the shipping views.
#
#   ./screenshots.sh --write    regenerate docs/*.png
#   ./screenshots.sh --check    regenerate into a temp dir and fail if docs/ differs
#
# Hand-taken screenshots rot the first time the UI moves and nobody notices.
# These come from the real views with fixed sample data, every varying input
# pinned (host label, version, time zone, locale, appearance), so two runs on
# one machine are byte-identical and a difference means the UI changed.
#
# --check is only meaningful on the machine the images were made on. Fonts and
# SDK differ across macOS versions and the hosted runner images lag, so CI runs
# it on the self-hosted Mac and nowhere else.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
DOCS="../docs"
# The version the settings pane shows in the pictures. Fixed, and not the real
# one: the release runner rewrites VERSION from the tag while the file in git
# stays behind, so a picture that tracked either would differ between the
# release and the next CI check and fail the drift test on every push after a
# release. A README image is an illustration, and this says so.
SHOWN="1.0.0"

render() { # $1 = output directory
  AGENT_INBOX_WRITE_SCREENSHOTS=1 AGENT_INBOX_SHOWN_VERSION="$SHOWN" \
  AGENT_INBOX_SCREENSHOT_DIR="$1" \
    swift test --filter ScreenshotTests 2>&1 | grep -E "^wrote|error:|failed" || true
}

case "${1:-}" in
  --write)
    render "$DOCS"
    ;;
  --check)
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    render "$TMP" >/dev/null
    status=0
    for f in "$TMP"/*.png; do
      n="$(basename "$f")"
      if [ ! -f "$DOCS/$n" ]; then
        echo "missing from docs/: $n"; status=1
      elif ! cmp -s "$f" "$DOCS/$n"; then
        echo "out of date: docs/$n"; status=1
      fi
    done
    # An image the README links to that no longer gets generated is a broken
    # picture on the front page.
    for ref in $(grep -o 'docs/[a-z-]*\.png' ../README.md | sort -u); do
      n="$(basename "$ref")"
      [ -f "$TMP/$n" ] || { echo "README links $ref but nothing generates it"; status=1; }
    done
    if [ "$status" -ne 0 ]; then
      echo "run mac/screenshots.sh --write and commit docs/" >&2
      exit 1
    fi
    echo "screenshots are current"
    ;;
  *)
    echo "usage: screenshots.sh --write | --check" >&2
    exit 2
    ;;
esac
