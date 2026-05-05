#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

[[ $# -ge 1 ]] || { echo "usage: screenshot.sh <context-slug>" >&2; exit 2; }
CONTEXT="$1"

# Reject path-shaped args. Output is auto-named from <slug>; an arg
# containing `/` or ending in `.png` is almost always a misuse where the
# caller assumed they were specifying the output path.
if [[ "$CONTEXT" == */* || "$CONTEXT" == *.png ]]; then
  echo "error: argument '$CONTEXT' looks like a path, not a slug." >&2
  echo "  screenshot.sh takes a context slug; output is auto-named:" >&2
  echo "    docs/screenshots/<timestamp>-<slug>.png" >&2
  echo "  example: screenshot.sh quiz-active" >&2
  echo "  to override path entirely, use: xcrun simctl io \$UDID screenshot <abs-path>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"

mkdir -p "$(pwd)/docs/screenshots"
TS=$(date +%Y%m%d-%H%M%S)
OUT="$(pwd)/docs/screenshots/${TS}-${CONTEXT}.png"
axe screenshot --udid "$UDID" --output "$OUT" >/dev/null
echo "$OUT"
