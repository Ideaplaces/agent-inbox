#!/usr/bin/env bash
# Open the VS Code window for a session recorded in the inbox.
#
#   open-session.sh <host> <cwd>
#
# Local sessions open directly; sessions from another machine open through
# VS Code's Remote-SSH, using <host> as the SSH host alias (which is how
# HOST_LABEL is meant to be set on remote machines).
HOST="${1:-}"
DIR="${2:-}"
[ -n "$DIR" ] || exit 0

CODE=/opt/homebrew/bin/code
[ -x "$CODE" ] || CODE="$(command -v code || true)"
[ -n "$CODE" ] || { open "$DIR" 2>/dev/null; exit 0; }

# A directory that also exists locally is assumed to be a local session. On two
# machines that share a directory layout this opens the local copy.
LOCAL="$(hostname -s)"
if [ -z "$HOST" ] || [ "$HOST" = "$LOCAL" ] || [ "$HOST" = "mac" ] || [ -d "$DIR" ]; then
  "$CODE" "$DIR"
else
  "$CODE" --folder-uri "vscode-remote://ssh-remote+$HOST$DIR"
fi
