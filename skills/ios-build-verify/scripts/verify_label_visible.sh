#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

[[ $# -ge 1 ]] || { echo "usage: verify_label_visible.sh <ax-label> [--role <role>]" >&2; exit 2; }
LABEL="$1"; shift
ROLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      [[ $# -ge 2 ]] || { echo "error: --role requires an argument." >&2; exit 2; }
      ROLE="$2"; shift 2 ;;
    *) echo "error: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"

TREE=$(axe describe-ui --udid "$UDID" 2>/dev/null)
COUNT=$(echo "$TREE" | jq --arg label "$LABEL" --arg role "$ROLE" '
  [.. | objects
   | select(.AXLabel? == $label and ($role == "" or .type? == $role))
  ] | length')

if [[ "$COUNT" -gt 0 ]]; then
  echo "visible: '$LABEL'${ROLE:+ ($ROLE)}"
  exit 0
fi

echo "error: '$LABEL'${ROLE:+ ($ROLE)} not present in AXTree." >&2
exit 4
