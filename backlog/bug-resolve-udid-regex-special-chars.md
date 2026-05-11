# Bug: `_resolve_udid.sh` fails for device names containing regex special characters

## Symptom

Sourcing `_resolve_udid.sh` (or running scripts that internally source it, like `launch_app.sh`) errors with:

```
error: no booted simulator named '<TARGET_SIM>'.
```

even when a simulator with that exact name **is** booted, **if** `TARGET_SIM` contains parentheses or other regex special characters.

This bites for any iPad named after Apple's standard format — `iPad Pro 13-inch (M4)`, `iPad Pro 13-inch (M5) (16GB)`, `iPad Pro 11-inch (M4)`, etc. — and for any user-named simulator that happens to include `(`, `)`, `[`, `]`, `?`, `*`, `+`, `.`, `\`, `^`, `$`, `|`, `{`, `}`.

The user-facing message is misleading: it says no simulator is booted when in fact one is — the matcher just couldn't find it. Operators reading the message will not suspect a regex-escaping issue.

## Reproduction

```bash
# 1. Create + boot a sim with a parenthesized name
UDID=$(xcrun simctl create "Demo iPad (M4)" \
  "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB" \
  "com.apple.CoreSimulator.SimRuntime.iOS-26-3")
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b

# 2. Configure ios-build-verify with that exact name
cat > .claude/ios-build-verify.config.sh <<EOF
APP_NAME=DemoApp
BUNDLE_ID=com.example.demo
PROJECT=Demo.xcodeproj
SCHEME=Demo
TARGET_SIM='Demo iPad (M4)'
FIRST_SCREEN_ID=foo
MAIN_TABS=()
MAIN_TABS_COORDS=()
MAIN_TAB_ANCHORS=()
WAIT_FOR_RENDER_BUDGET_S=10
ONBOARDING_DISMISS_LABEL='Skip'
EOF

# 3. Try to resolve the UDID
source .claude/ios-build-verify.config.sh
"$IBV_SCRIPTS/_resolve_udid.sh"
# error: no booted simulator named 'Demo iPad (M4)'.
```

## Root cause

`_resolve_udid.sh` line 16:

```bash
UDID=$(xcrun simctl list devices booted \
  | grep -E "^[[:space:]]+${TARGET_SIM} \(" \
  | grep -oE '[0-9A-F-]{36}' \
  | tail -1) || true
```

`${TARGET_SIM}` is interpolated into a `grep -E` (extended regex) without escaping regex metacharacters. For `TARGET_SIM='Demo iPad (M4)'`, the regex becomes:

```
^[[:space:]]+Demo iPad (M4) \(
```

The `(M4)` is interpreted as a regex capture group containing the literal `M4`. This regex matches the string `Demo iPad M4 (` (with the parens around `M4` consumed as group syntax, not literal characters), which doesn't match the actual `xcrun simctl list devices booted` output line:

```
    Demo iPad (M4) (3F8E2C70-...) (Booted)
```

Match fails; UDID stays empty; script exits with code 3 and the misleading "no booted simulator" message.

## Suggested fix

Switch to fixed-string match:

```bash
UDID=$(xcrun simctl list devices booted \
  | grep -F "    ${TARGET_SIM} (" \
  | grep -oE '[0-9A-F-]{36}' \
  | tail -1) || true
```

`grep -F` does literal substring matching; no regex interpretation. The 4-space prefix can be retained for safety against partial-name matches, or omitted (the unique `<name> (UDID)` shape per line is sufficient disambiguation for fixed-string match).

Alternative (preserves `grep -E` semantics): regex-quote `TARGET_SIM` before interpolation:

```bash
quoted=$(printf '%s\n' "${TARGET_SIM}" | sed -E 's/[][\\.*+?(){}^$|]/\\&/g')
UDID=$(xcrun simctl list devices booted \
  | grep -E "^[[:space:]]+${quoted} \(" \
  | grep -oE '[0-9A-F-]{36}' \
  | tail -1) || true
```

`grep -F` is simpler and equally correct.

A clearer error message would also help when the lookup genuinely fails: include the booted-device list in the diagnostic, so operators can spot a name mismatch without running `xcrun simctl list devices booted` themselves.

## Workaround for end users (no upstream change required)

Rename the simulator to a name without regex specials before sourcing the config:

```bash
xcrun simctl rename <UDID> "Demo iPad M4"
# Then set TARGET_SIM='Demo iPad M4' in the config
```

`xcrun simctl rename` is metadata-only — doesn't affect boot state, installed apps, build artifacts, or the device's UDID.

## How this surfaced

Discovered during Step 2 calibration of the Konjugieren screenshot-automation effort (May 2026). The original screenshot-automation handoff prescribed `TARGET_SIM='iPad Pro 13-inch (M4)'`; the calibration session hit the silent regex failure on first attempt. Workaround applied: created a renamed sim `'Konjugieren iPad Screenshots'`. Documented in that project's `docs/screenshot-calibration-values.md` Finding #1.

## Affected versions

Verified affected: skill version `0.2.1` at path:

```
~/.claude/plugins/marketplaces/ios-build-verify/skills/ios-build-verify/scripts/_resolve_udid.sh
```

Likely affected: all prior versions where the script existed. The script's own header comment refers to a "Session 6 / Session 7" fix for a prior `head -1` issue; that fix didn't address regex escaping in the `TARGET_SIM` interpolation.

## Severity

**Medium-low**. Silent failure with a misleading error message, but the workaround (rename the sim) is trivial once the cause is understood. Several scripts in the verify half (`launch_app.sh`, `tap_tab.sh`, `screenshot.sh`, `describe_ui.sh`, etc.) all source `_resolve_udid.sh`, so the bug surfaces uniformly across the verify operations rather than in one isolated place.
