#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
START=$(date +%s)

ok()   { echo "✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "✗ $*"; FAIL=$((FAIL + 1)); }

# 1. build (blocking on failure)
if "$SCRIPT_DIR/build_app.sh" >/dev/null 2>&1; then
  ok "build"
else
  fail "build (build_app.sh failed; rerun directly to see xcodebuild output, or check build.log)"
  echo "smoke_test.sh: aborting — cannot proceed without a successful build."
  exit 1
fi

# 2. launch (blocking on failure)
LAUNCH_START=$(date +%s)
if LAUNCH_OUT=$("$SCRIPT_DIR/launch_app.sh" 2>&1); then
  LAUNCH_ELAPSED=$(($(date +%s) - LAUNCH_START))
  ok "launch (FIRST_SCREEN_ID '$FIRST_SCREEN_ID' seen in ${LAUNCH_ELAPSED}s)"
else
  LAUNCH_RC=$?
  case "$LAUNCH_RC" in
    4) fail "launch (.app missing — rerun build_app.sh)" ;;
    5) fail "launch (FIRST_SCREEN_ID '$FIRST_SCREEN_ID' never appeared — see SKILL.md 'Common first-real-app friction' items 1, 2, 6)" ;;
    *) fail "launch (exit $LAUNCH_RC)" ;;
  esac
  echo "$LAUNCH_OUT" | tail -3
  echo "smoke_test.sh: aborting — cannot drive tabs without a launched app."
  exit 1
fi

source "$SCRIPT_DIR/_resolve_udid.sh"

# 3. screenshot the launch screen
if "$SCRIPT_DIR/screenshot.sh" smoke-launch >/dev/null 2>&1; then
  ok "screenshot smoke-launch"
else
  fail "screenshot smoke-launch (screenshot.sh failed)"
fi

# 4. iterate tabs
HAS_TABS=0
if [[ "${MAIN_TABS+x}" && ${#MAIN_TABS[@]} -gt 0 ]]; then
  HAS_TABS=1
fi

HAS_ANCHORS=0
if [[ "${MAIN_TAB_ANCHORS+x}" && ${#MAIN_TAB_ANCHORS[@]} -gt 0 ]]; then
  HAS_ANCHORS=1
  if [[ "$HAS_TABS" -eq 1 && ${#MAIN_TAB_ANCHORS[@]} -ne ${#MAIN_TABS[@]} ]]; then
    fail "MAIN_TAB_ANCHORS has ${#MAIN_TAB_ANCHORS[@]} entries but MAIN_TABS has ${#MAIN_TABS[@]}; counts must match — falling back to AXTree-changed verification"
    HAS_ANCHORS=0
  fi
fi

if [[ "$HAS_TABS" -eq 0 ]]; then
  echo "  (skipping per-tab smoke: MAIN_TABS empty — no TabView to drive)"
else
  for i in "${!MAIN_TABS[@]}"; do
    TAB="${MAIN_TABS[$i]}"

    BEFORE_FP=$(axe describe-ui --udid "$UDID" 2>/dev/null | shasum -a 256 | awk '{print $1}')

    if "$SCRIPT_DIR/tap_tab.sh" "$TAB" >/dev/null 2>&1; then
      sleep 0.5  # let the tab transition settle (typically 100–300ms; 0.5s is over-generous but cheap)
      "$SCRIPT_DIR/screenshot.sh" "smoke-tab-$TAB" >/dev/null 2>&1 || true

      if [[ "$HAS_ANCHORS" -eq 1 ]]; then
        ANCHOR="${MAIN_TAB_ANCHORS[$i]}"
        if "$SCRIPT_DIR/verify_label_visible.sh" "$ANCHOR" >/dev/null 2>&1; then
          ok "tab $TAB (anchor '$ANCHOR' visible)"
        else
          fail "tab $TAB (anchor '$ANCHOR' not present — check the label exact-match, or see SKILL.md 'Identifier rollup' if a parent container's identifier is masking the leaf)"
        fi
      else
        AFTER_FP=$(axe describe-ui --udid "$UDID" 2>/dev/null | shasum -a 256 | awk '{print $1}')
        if [[ "$BEFORE_FP" != "$AFTER_FP" ]]; then
          ok "tab $TAB (AXTree changed; no MAIN_TAB_ANCHORS configured)"
        else
          fail "tab $TAB (AXTree unchanged after tap_tab.sh — tap may not have landed; calibrate MAIN_TABS_COORDS via measure_tab_pill.sh, or set MAIN_TAB_ANCHORS for explicit per-tab assertions)"
        fi
      fi
    else
      TAP_RC=$?
      case "$TAP_RC" in
        4) fail "tab $TAB (tap_tab.sh exit 4 — tab name not in MAIN_TABS, coord-count mismatch, or no coords for '$TARGET_SIM' — see SKILL.md 'iOS 26 Tab-bar coordinate fallback')" ;;
        7) fail "tab $TAB (tap_tab.sh exit 7 — tab-pill overlap)" ;;
        *) fail "tab $TAB (tap_tab.sh exit $TAP_RC)" ;;
      esac
    fi
  done
fi

# 5. terminate
if "$SCRIPT_DIR/terminate_app.sh" >/dev/null 2>&1; then
  ok "terminate"
else
  fail "terminate (terminate_app.sh failed)"
fi

ELAPSED=$(($(date +%s) - START))
echo "---"
echo "smoke_test.sh: $PASS pass, $FAIL fail, ${ELAPSED}s"
[[ "$FAIL" -eq 0 ]] || exit 1
