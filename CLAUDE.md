This project contains the implementation of ios-build-verify, a skill intended for iOS-development use in Claude Code.

Josh Adams is the author and maintainer of ios-build-verify.

The skill bundles two halves of the iOS agentic-coding loop. The build half pipes `xcodebuild` through `xcbeautify` for token-cheap building and unit testing, with raw output mirrored to a build.log file as a diagnostic fallback. The verify half pairs AXe, a Swift-native simulator-automation CLI, with `xcrun simctl` and exposes them through named-intent operations: launch the app, tap a control by its accessibility identifier, read or set a field's value, verify a screen has loaded, screenshot a named view, and audit a view for missing accessibility modifiers. State checks read AXe's `describe-ui` accessibility-tree dump rather than screenshots, favoring text before pixels. Screenshots land on disk and are read only when layout, typography, color, or spacing are actually under review.

## Repository layout

- `skills/ios-build-verify/SKILL.md` — canonical reference for every operation, exit code, and worked example. Authoritative (~107K); consult it before inferring semantics from script filenames.
- `skills/ios-build-verify/scripts/` — bash entrypoints for every operation. Scripts whose names start with `_` (e.g., `_resolve_udid.sh`, `_check_pill_overlap.sh`, `_classify_present_ids.sh`) are sourced helpers, not standalone commands; reach them through the public scripts that source them.
- `skills/ios-build-verify/data/coordinates.json` — per-project tab-pill coordinate data, edited per project.
- `.claude-plugin/plugin.json` — plugin manifest. Bump `version` on release.
- `.claude-plugin/marketplace.json` — marketplace listing.
- `prompts/` — validation-session writeups; not loaded by the skill at runtime.

## Runtime contract

- Every script reads `$(pwd)/.claude/ios-build-verify.config.sh` and exits 2 if it is missing. Required fields: `APP_NAME`, `BUNDLE_ID`, `SCHEME`, `TARGET_SIM`, `FIRST_SCREEN_ID`. Run `setup_project.sh` first to write it.
- Verify-half ops require a simulator named `TARGET_SIM` to be booted; `_resolve_udid.sh` exits 3 otherwise. Run `launch_app.sh` (which boots and installs) before any tap / read / verify op.
- `launch_app.sh` exits 4 if the built `.app` is missing. Run `build_app.sh` first.
- `calibrate.sh` requires Python Pillow; `measure_tab_pill.sh` exits 4 with install instructions if missing. Calibration is a once-per-project step.
- Public scripts use `set -euo pipefail`. Follow the convention in any new script.
- Standard exit codes used across named-intent ops: `2` = config / argument problem; `3` = no booted simulator matches `TARGET_SIM`; `4` = identifier or required state not present in the AXTree (carries the "present AXUniqueIds in the tree" classifying hint); `5` = launch anchor (`FIRST_SCREEN_ID`) never appeared within `WAIT_FOR_RENDER_BUDGET_S`; `6` = read-back / value mismatch; `7` = state probe (e.g., tab-pill overlap, segment-not-selected); `8` = `tap_xy.sh --verify-target` / `--verify-role` mismatch (the AXLabel or role under the tap coordinate didn't match what was asserted; no tap dispatched).

## Common verify-half friction

Every item below is a silent or near-silent failure mode that costs an agent real time on first encounter. Each is one-liner here; full treatment lives in SKILL.md and the validation writeups under `prompts/`.

- **Logical points, not pixels.** AXe (`axe tap`, `axe swipe`, `axe describe-ui`) consumes logical points. `xcrun simctl io <UDID> screenshot` writes a PNG in pixels at the device's native scale (3× on iPhone 17 / 17 Pro / 17 Plus). Mixing them sends taps far off-screen and looks like a silent failure. Divide pixel coordinates by the scale factor, or read a logical-point frame directly via `describe_ui.sh --point <x>,<y>` (per-point inspection — also reaches sub-elements that the full tree misses; sample JSON walk in `prompts/agent-ui-audit-validation.md`).
- **Empty AXTree on launch = modal gating.** `launch_app.sh` exit 5 with `children: []` means a modal (review prompt, onboarding, system alert, IAP paywall, custom permission primer) is gating describe-ui before `FIRST_SCREEN_ID` can be polled. The full-tree dump is empty; reach the dismiss button via `describe_ui.sh --point <x>,<y>`. See SKILL.md "Common first-real-app friction" item 6.
- **iOS 26 SwiftUI `TabView(.page)` cannot be advanced by `axe swipe`.** The gesture executes but the page coordinator's velocity threshold rejects it; page-indicator dots are not hit-testable as accessibility elements. Recovery: read source to understand the page sequence, then dismiss the modal entirely or drive `selection: $currentPage` programmatically.
- **SwiftUI identifier rollup.** A parent's `.accessibilityIdentifier()` cascades to every descendant in the AXTree. An identifier on `VStack` / `ZStack` / `HStack` / `Form` / `NavigationStack` defeats verification because every element shares the ID. Move identifiers to leaves, or wrap parents in `.accessibilityElement(children: .contain)`. See SKILL.md "Identifier rollup."
- **`screenshot.sh` takes a slug, not a path.** `screenshot.sh quiz-active` produces `docs/screenshots/<timestamp>-quiz-active.png`. Passing a path-shaped argument (e.g., `docs/screenshots/foo.png`) produces a nested filename like `docs/screenshots/<timestamp>-docs/screenshots/foo.png.png`. To override the path entirely, drop to `xcrun simctl io <UDID> screenshot <abs-path>`.
- **`axe key` uses a positional keycode, not a `--keycode` flag.** `axe key 40` (return), `42` (backspace), `41` (escape). Modifiers via `axe key-combo --modifiers <mask> --key <code>` — Cmd+A is mask 227, key 4.
- **`tap_xy.sh` confirms the gesture, not the target.** Coordinate-based taps from agent-estimated screenshot positions are inherently fuzzy. A "tap completed successfully" report only means the gesture executed, not that the intended element was hit. For an integrated guarded dispatch, pass `tap_xy.sh <x> <y> --verify-target "<expected-axlabel>"` (exit 8 if the AXLabel under the coordinate doesn't match — no tap dispatched). Otherwise pre-verify with `describe_ui.sh --point <x>,<y>` or assert a post-condition with a `verify_*` op afterwards.
- **`set_value.sh` requires an accessibility identifier.** There is no shipped wrapper for tap-to-focus + type into an unidentified `TextField`. The underlying primitive is `axe type "$TEXT" --udid "$UDID"`; compose it with a coordinate tap when needed. `xcrun simctl io <UDID> type "..."` is **not a real subcommand** — it silently no-ops; do not reach for it.

More information on ios-build-verify and its development is available [here](https://racecondition.software/blog/ios-build-verify/). [This](https://github.com/vermont42/ios-build-verify) is the skill's GitHub repo.
