# Bug: `axe tap --id` and `axe tap --label` raise Swift `typeMismatch` on iPad in some screen states

## Symptom

`axe tap --id <id> --udid <iPad UDID>` (and the same with `--label`) errors with:

```
Error: typeMismatch(Swift.Dictionary<Swift.String, Any>, Swift.DecodingError.Context(codingPath: [], debugDescription: "Expected to decode Dictionary<String, Any> but found an array instead.", underlyingError: nil))
```

Exit code: `1`. No tap is performed.

The same identifier-based tap works on iPhone simulators with the same iOS runtime. `axe describe-ui` and `axe tap -x <x> -y <y>` (coordinate-based) work fine on the affected iPad screens — only the accessibility-lookup tap variants (`--id`, `--label`) raise.

This propagates upward through every ios-build-verify script that resolves elements by ID or label internally:

- `scripts/tap_id.sh` (calls `axe tap --id`)
- `scripts/tap_label.sh` (calls `axe tap --label`)
- `scripts/dismiss_onboarding.sh` (calls `axe tap --label` after `axe describe-ui`)
- `scripts/set_value.sh` / `scripts/type_text.sh --id …` (route through `tap_id.sh`)
- Any audit/verify script that internally resolves by accessibility identifier

The user-facing message is opaque: it surfaces an internal Codable parse error from `axe`, which doesn't suggest "use coordinate-based tap" or "this is iPad-specific."

## Reproduction

Encountered with skill version `0.2.1`, iOS 26.3.1 on iPad Pro 13-inch (M4) sim. Likely reproduces on other iPad sims with iOS 26.3+.

```bash
# 1. Boot iPad sim, install some app, navigate to a screen with a tappable
#    element that has an accessibilityIdentifier, e.g., the QuizView's Start
#    button in the Konjugieren project (id = "quiz_start_button").

# 2. Confirm describe-ui sees the element:
axe describe-ui --udid <IPAD_UDID> | jq '[.. | objects | select(.AXUniqueId? == "quiz_start_button")] | length'
# 1 (or more, if SwiftUI propagated)

# 3. Try identifier-based tap:
axe tap --id quiz_start_button --udid <IPAD_UDID>
# Error: typeMismatch(Swift.Dictionary<Swift.String, Any>, ...)
# exit 1

# 4. Try label-based tap (same backend code path):
axe tap --label "Start" --udid <IPAD_UDID>
# Error: typeMismatch(Swift.Dictionary<Swift.String, Any>, ...)
# exit 1

# 5. Coordinate-based tap on the same element (works):
FRAME=$(axe describe-ui --udid <IPAD_UDID> | jq -r '[.. | objects | select(.AXUniqueId? == "quiz_start_button")][0].AXFrame')
# extract x+w/2, y+h/2 from FRAME
axe tap -x <cx> -y <cy> --udid <IPAD_UDID>
# OK
```

The iPhone equivalent (same app, same identifier, iPhone 17 Pro Max sim, iOS 26.3.1) works without error.

## Root cause (best guess — needs upstream investigation)

The error is internal to `axe`'s Swift code. From the error message, axe is decoding an accessibility-tree response from CoreSimulator and expecting a Dictionary at the root, but receiving an Array instead.

Hypothesis: when iPad's regular size class is active, the AX tree's response structure for some elements differs from compact size class — most likely because the sidebar/split-view container at the top of the tree wraps the matched element under an additional layer of array-typed children that axe's decoder doesn't account for. iPhone's compact size class doesn't have this container, so the decoder's expected shape matches.

This is consistent with the observation that `axe describe-ui` (which presumably has a more permissive/recursive decoder) handles the same tree without issue. Only the `--id`/`--label` lookup path — which appears to assume a particular shape — fails.

A maintainer should verify by enabling verbose decoding in `axe` and capturing the offending JSON payload from a failing case.

## Suggested fix

Two paths:

1. **Upstream `axe`**: relax the lookup-path decoder to handle both Dictionary-rooted and Array-rooted accessibility tree responses, or normalize the response shape before decoding. The describe-ui path already handles whatever shape CoreSimulator returns; the lookup paths should match.

2. **Skill-level fallback**: if upstream isn't quickly fixable, `tap_id.sh` and `tap_label.sh` could detect the typeMismatch error and fall back to coordinate-based tap via:
   - `axe describe-ui`
   - `jq` to find the matched element's `AXFrame`
   - `axe tap -x <cx> -y <cy>`

   The Konjugieren screenshot driver implements exactly this (see `scripts/take_screenshots.sh::tap_id_first` in the linked workaround). Upstreaming that pattern into the skill would make `tap_id.sh` robust without app-level intervention.

## Workaround for end users (no upstream change required)

Bypass `axe tap --id`/`--label` and use a describe-ui + coord-tap pattern. Pseudocode:

```bash
tap_id_via_coords() {
  local id="$1" udid="$2"
  local frame x y w h cx cy
  frame=$(axe describe-ui --udid "$udid" 2>/dev/null \
    | jq -r --arg id "$id" '[.. | objects | select(.AXUniqueId? == $id)][0].AXFrame // ""')
  [[ -z "$frame" || "$frame" == "null" ]] && return 1
  read -r x y w h <<< "$(echo "$frame" | sed -E 's/[{},]/ /g; s/  +/ /g' | awk '{print $1, $2, $3, $4}')"
  cx=$(awk "BEGIN{printf \"%.2f\", $x + $w/2}")
  cy=$(awk "BEGIN{printf \"%.2f\", $y + $h/2}")
  axe tap -x "$cx" -y "$cy" --udid "$udid"
}
```

This pattern has the side benefit of handling SwiftUI's accessibility-identifier propagation (where one identifier matches multiple child elements) — `axe tap --id` refuses multi-match cases, but the first-match-by-frame approach picks the parent NavigationLink/Button.

## How this surfaced

Discovered during Step 3 of the Konjugieren screenshot-automation effort (May 2026). The driver was working through cells in order; iPhone passes worked end-to-end. On the first iPad cell that needed `tap_id` (`quiz_start_button` after `tap_tab quiz`), axe raised the typeMismatch error.

Documented in the project's `scripts/take_screenshots.sh` comment at the unified `tap_id` definition:

> `axe tap --id` and `axe tap --label` throw a Swift typeMismatch decoding error in some iPad screen states (e.g., the QuizView pre-Start state). describe-ui works in those states, so coord-tap is the safe path.

## Affected versions

Verified affected: skill version `0.2.1` (`axe` binary version unknown — `axe --version` not surfaced in skill metadata). Path:

```
~/.claude/plugins/marketplaces/ios-build-verify/skills/ios-build-verify/scripts/tap_id.sh
~/.claude/plugins/marketplaces/ios-build-verify/skills/ios-build-verify/scripts/tap_label.sh
~/.claude/plugins/marketplaces/ios-build-verify/skills/ios-build-verify/scripts/dismiss_onboarding.sh
```

Verified host context: macOS 24.6 (Darwin 24.6.0), Xcode 26.3, iOS 26.3.1 simulator runtime, Intel Mac. iPad Pro 13-inch (M4) sim.

Not verified: whether the bug reproduces on Apple Silicon hosts, on older iOS runtimes, or on iPhone sims in any specific state. Worth checking whether iPad's regular size class is the trigger vs. something more specific to the QuizView's view hierarchy.

## Severity

**Medium**. Hard-fails a core skill operation (identifier-based tap) on a major device class (iPad), with no skill-side fallback and an opaque error message that doesn't hint at the workaround. Apps targeting both iPhone and iPad need to know to bypass `tap_id.sh` for iPad runs, or the verify-half scripts silently fail on every iPad cell.

The describe-ui-plus-coord-tap workaround is robust and easy to drop in at the skill level (it's already battle-tested in the Konjugieren driver) — fixing this in `tap_id.sh` and `tap_label.sh` would make most apps' iPad coverage "just work" again.

## Resolution

Fixed upstream in AXe at commit [`1a23f1cc`](https://github.com/cameroncooke/AXe/commit/1a23f1cc) (2026-05-11), "fix(accessibility): Expose SwiftUI TabView tabs." The maintainer added a defensive `init(from:)` on `AccessibilityElement` that decodes String / Int / Double / Bool / null for every scalar field, hardening against the same Number→String? typeMismatch class on `AXLabel`, `AXUniqueId`, `AXIdentifier`, `AXValue`, and the other scalar fields. E2E coverage for a `Slider` fixture and numeric-`AXValue` decoding landed alongside in [PR #48](https://github.com/cameroncooke/AXe/pull/48). At time of fix the latest tagged AXe release was v1.6.0 (2026-04-05), which predates the commit; the fix is currently available via `brew tap cameroncooke/axe-staging` until the next tag ships.

**The "iPad-specific" hypothesis in the root-cause section above turned out to be wrong.** Subsequent investigation (May 2026 GenericApp / GenericApp2 sessions, filed upstream as [cameroncooke/AXe#45](https://github.com/cameroncooke/AXe/issues/45)) isolated the actual mechanism: AXe's `AccessibilityElement.AXValue` was hard-typed `String?`, and any element emitting `AXValue` as a JSON Number (SwiftUI `Slider`, `Picker(.wheel)`-backed `AXSlider`) broke whole-tree decode. The Konjugieren iPad QuizView happened to contain a Slider; the iPhone equivalent that worked end-to-end did not. The "Dictionary vs Array" framing in the symptom message above was a red herring caused by a `try?`-swallow + retry in AXe's decode path that converted the real `Number → String?` typeMismatch into a misleading shape-mismatch message.

The skill-side coordinate-tap fallback proposed under "Suggested fix > 2. Skill-level fallback" was not implemented; the upstream fix made it unnecessary. Follow-up skill changes in response to the upstream fix (reframing the SKILL.md "Slider AXTree" section, demoting the `audit_view.sh` foot-gun scanner, etc.) are tracked in `backlog/axe-slider-fix-skill-updates.md`.
