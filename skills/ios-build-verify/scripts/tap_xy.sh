#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

VERIFY_LABEL=""
VERIFY_ROLE=""
HAVE_VERIFY_LABEL=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-target)
      [[ $# -ge 2 ]] || { echo "error: --verify-target requires an argument." >&2; exit 2; }
      VERIFY_LABEL="$2"; HAVE_VERIFY_LABEL=1; shift 2 ;;
    --verify-role)
      [[ $# -ge 2 ]] || { echo "error: --verify-role requires an argument." >&2; exit 2; }
      VERIFY_ROLE="$2"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
usage: tap_xy.sh <x> <y> [--verify-target <expected-axlabel>] [--verify-role <role>]
  <x> <y>            logical-point coordinates (origin top-left).
  --verify-target L  pre-query the element under (x,y) via
                     `axe describe-ui --point` and refuse to tap unless its
                     AXLabel == L. Catches off-by-pixel taps that AXe
                     reports as a successful gesture but actually land on
                     the wrong element. Recommended after agent-estimated
                     screenshot positions.
  --verify-role R    optional. When AXLabel collides across roles (a Button
                     and a StaticText with the same visible text), require
                     the pre-queried role to equal R. Pass the role string
                     exactly as `describe_ui.sh --point x,y` reports it.

Exit codes:
  0  tap dispatched
  2  config missing, non-numeric input, or argument-parse error
  3  no booted simulator matches TARGET_SIM
  8  --verify-target / --verify-role mismatch (no tap dispatched; the actual
     element's AXLabel, role, and AXFrame are written to stderr)
EOF
      exit 0 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

[[ $# -ge 2 ]] || { echo "usage: tap_xy.sh <x> <y> [--verify-target <expected-axlabel>] [--verify-role <role>]" >&2; exit 2; }
X="$1"; Y="$2"

if [[ -n "$VERIFY_ROLE" && "$HAVE_VERIFY_LABEL" -eq 0 ]]; then
  echo "error: --verify-role requires --verify-target (role check runs only when label check is requested)." >&2
  exit 2
fi

NUMERIC_RE='^-?[0-9]+(\.[0-9]+)?$'
[[ "$X" =~ $NUMERIC_RE ]] || { echo "error: x must be numeric, got '$X'." >&2; exit 2; }
[[ "$Y" =~ $NUMERIC_RE ]] || { echo "error: y must be numeric, got '$Y'." >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"

if [[ "$HAVE_VERIFY_LABEL" -eq 1 ]]; then
  POINT_JSON=$(axe describe-ui --point "${X},${Y}" --udid "$UDID" 2>/dev/null || true)
  if [[ -z "$POINT_JSON" ]]; then
    echo "error: --verify-target: 'axe describe-ui --point ${X},${Y}' returned no element (the coordinate may fall in dead space, off-screen, or under a transient overlay). No tap dispatched." >&2
    exit 8
  fi
  ACTUAL_LABEL=$(echo "$POINT_JSON" | jq -r '.AXLabel // ""' 2>/dev/null || echo "")
  ACTUAL_ROLE=$(echo "$POINT_JSON"  | jq -r '.role // .type // ""' 2>/dev/null || echo "")
  ACTUAL_FRAME=$(echo "$POINT_JSON" | jq -r '.AXFrame // .frame // ""' 2>/dev/null || echo "")

  if [[ "$ACTUAL_LABEL" != "$VERIFY_LABEL" ]]; then
    echo "error: --verify-target: expected AXLabel '$VERIFY_LABEL', got '$ACTUAL_LABEL' (role: '$ACTUAL_ROLE', frame: $ACTUAL_FRAME). No tap dispatched." >&2
    exit 8
  fi
  if [[ -n "$VERIFY_ROLE" && "$ACTUAL_ROLE" != "$VERIFY_ROLE" ]]; then
    echo "error: --verify-role: expected role '$VERIFY_ROLE', got '$ACTUAL_ROLE' (label matched: '$ACTUAL_LABEL', frame: $ACTUAL_FRAME). No tap dispatched." >&2
    exit 8
  fi
fi

axe tap -x "$X" -y "$Y" --udid "$UDID"
