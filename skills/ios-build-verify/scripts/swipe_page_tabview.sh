#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

# Defaults: wide right-to-left horizontal swipe across the iPhone 17 viewport
# at vertical mid, slow enough to clear most page-coordinator velocity
# thresholds (when those thresholds are reachable at all on iOS 26).
START_X=350
START_Y=425
END_X=43
END_Y=425
DURATION=0.8

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-x)  [[ $# -ge 2 ]] || { echo "error: --start-x requires a value." >&2; exit 2; }; START_X="$2";  shift 2 ;;
    --start-y)  [[ $# -ge 2 ]] || { echo "error: --start-y requires a value." >&2; exit 2; }; START_Y="$2";  shift 2 ;;
    --end-x)    [[ $# -ge 2 ]] || { echo "error: --end-x requires a value." >&2; exit 2; };   END_X="$2";    shift 2 ;;
    --end-y)    [[ $# -ge 2 ]] || { echo "error: --end-y requires a value." >&2; exit 2; };   END_Y="$2";    shift 2 ;;
    --duration) [[ $# -ge 2 ]] || { echo "error: --duration requires a value." >&2; exit 2; }; DURATION="$2"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
usage: swipe_page_tabview.sh [--start-x N] [--start-y N] [--end-x N] [--end-y N] [--duration S]

Wide horizontal swipe with extended duration, intended as a forward page
advance for paged TabView (.tabViewStyle(.page)). Fingerprints the AXTree
before and after; on no change, exits 7 with a hint pointing at the iOS 26
SwiftUI gesture-injection wall (SKILL.md "Common first-real-app friction"
item 7).

Defaults: (350,425) → (43,425), duration 0.8s — right-to-left across most of
the iPhone 17 viewport. Override via flags for back swipes, vertical paged
TabViews, or alternate viewport sizes.
EOF
      exit 0 ;;
    *) echo "error: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"

BEFORE=$(axe describe-ui --udid "$UDID" 2>/dev/null | shasum -a 256 | awk '{print $1}')

axe swipe \
  --start-x "$START_X" --start-y "$START_Y" \
  --end-x "$END_X" --end-y "$END_Y" \
  --duration "$DURATION" \
  --udid "$UDID" >/dev/null

sleep 0.3  # let any animation settle before re-fingerprinting
AFTER=$(axe describe-ui --udid "$UDID" 2>/dev/null | shasum -a 256 | awk '{print $1}')

if [[ "$BEFORE" != "$AFTER" ]]; then
  echo "swipe advanced: AXTree changed (${START_X},${START_Y}) → (${END_X},${END_Y})"
  exit 0
fi

cat >&2 <<EOF
error: swipe did not advance the page (AXTree unchanged after gesture).
  hint: this is the iOS 26 SwiftUI TabView(.page) gesture-injection wall —
        the swipe executes but the page coordinator's velocity threshold
        rejects it. Page-indicator dots are not hit-testable either. See
        SKILL.md → "Common first-real-app friction" item 7 for recovery
        options (read source, dismiss the modal entirely, or drive
        \`selection: \$currentPage\` programmatically).
EOF
exit 7
