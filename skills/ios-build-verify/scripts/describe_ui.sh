#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

POINT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --point) POINT="$2"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
usage: describe_ui.sh [--point x,y]
  (no args)   dump the full AXTree as JSON.
  --point x,y describe the single element at logical-points coordinate (x,y).
              Reaches sub-elements that the full-tree dump misses (segmented
              Picker segments, popover options, modal-gated dismiss buttons),
              and is the recommended path when the full tree is empty
              (modal-gated launch — see SKILL.md "Common first-real-app
              friction" item 6) or when a control is subject to the iOS 26
              children-not-enumerated bug.

Coordinates are logical points (origin top-left), not pixels — see SKILL.md
"Per-point inspection".

Exit codes:
  0  success
  2  config missing or malformed --point argument
  3  no booted simulator matches TARGET_SIM
EOF
      exit 0 ;;
    *)
      echo "error: unknown arg '$1' (expected --point x,y)." >&2
      exit 2 ;;
  esac
done

if [[ -n "$POINT" ]] && ! [[ "$POINT" =~ ^-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?$ ]]; then
  echo "error: --point must be 'x,y' with numeric coordinates (got '$POINT')." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"

if [[ -n "$POINT" ]]; then
  axe describe-ui --point "$POINT" --udid "$UDID"
else
  axe describe-ui --udid "$UDID"
fi
