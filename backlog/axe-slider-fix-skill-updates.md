# Implementation prompt: ios-build-verify updates in response to upstream AXe slider-AXValue fix

## Context

You are working in `~/Desktop/workspace/ios-build-verify` — the source repo for the `ios-build-verify` Claude Code skill, published at `https://github.com/vermont42/ios-build-verify`.

In May 2026 a session-wide `tap_id` resolver-poisoning bug was isolated to SwiftUI `Slider` (and `Picker(.wheel)`-backed `AXSlider`) rendering — any element emitting `AXValue` as a JSON Number broke AXe's whole-tree decode because `AccessibilityElement.AXValue` was hard-typed `String?`. The investigation was filed upstream as [cameroncooke/AXe#45](https://github.com/cameroncooke/AXe/issues/45). The bug shaped a substantial portion of the skill — `SKILL.md` "Slider AXTree" section, `audit_view.sh`'s `slider_wheel_scan()` foot-gun scanner, several Picker-section paragraphs, and the cheat-sheet entries for Slider and Picker.

That upstream bug is now fixed on `main`.

## Verification of the upstream fix

**Fix landed at commit [`1a23f1cc`](https://github.com/cameroncooke/AXe/commit/1a23f1cc) (2026-05-11), "fix(accessibility): Expose SwiftUI TabView tabs."** The commit message includes the line *"Normalize scalar accessibility values so numeric tab selected-state values do not break decoding,"* which is the direct fix for issue #45. The diff to `Sources/AXe/Utilities/AccessibilityElement.swift` adds a custom `init(from decoder:)` and a `decodeOptionalScalarString` helper that defensively decodes String / Int / Double / Bool / null for **every** scalar field — `type`, `role`, `roleDescription`, `subrole`, `AXLabel`, `AXUniqueId`, `AXIdentifier`, `AXValue`. The downstream field shape stays `String?`, so nothing in the skill's `jq` pipelines needs to change.

**PR #48 is *not* the fix.** The maintainer pointed at PR [#48](https://github.com/cameroncooke/AXe/pull/48) ("test(accessibility): Add navigation chrome fixtures"), but its body explicitly says: *"The implementation fixes for these cases are already present on main via the TabView accessibility-client work; this PR keeps the follow-up verification separate from the still-riskier slider precision work."* PR #48 adds a SwiftUI `Slider` fixture and an E2E test that proves the fix holds; it's wired to `Fixes #45` so the issue auto-closed when #48 merged. The actual fix rode in `1a23f1cc` earlier the same day.

**The fix differs from the originally-suggested shape.** The bug report proposed a polymorphic `enum AXValueField { case string, case number }`. The maintainer instead kept `AXValue: String?` and routed it through a defensive scalar-decoder applied to all scalar fields. More comprehensive — it hardens against the same Number→String? class on every other scalar field, in case iOS ever serializes one as a Number/Bool under some future role. The other suggestion in the bug report — a peek-the-first-non-whitespace-byte dispatch in `AccessibilityFetcher.swift` to distinguish array-shape from dict-shape responses and surface the real `Number → String?` typeMismatch instead of the misleading "Dictionary vs Array" rewrite — was **not** adopted. The `try?`-swallow + retry pattern remains. For the slider case it no longer matters (the first decode now succeeds), but the misleading error message can still surface for any *other* shape mismatch that arises in the future.

**Release status: not yet shipped in a tagged release.** Latest production tag is **v1.6.0** (2026-04-05), which predates the fix. The fix is only available via the staging tap:

```
brew tap cameroncooke/axe-staging
brew install cameroncooke/axe-staging/axe
# staging-main-33-1a23f1c or newer
```

Users who installed AXe via the standard `brew install axe` still hit the bug. Any skill update that assumes "the user has the fix" needs to either wait for a tagged release (presumably v1.6.1 or later) or version-gate at runtime against `axe --version`.

## Design principle to apply

**Leave the historical record intact; reframe the operational guidance.** The skill's Slider material grew out of multi-session investigation and is referenced from `backlog/done/bug-axe-tap-id-ipad-typemismatch.md`, the May 2026 GenericApp / GenericApp2 writeups, and CLAUDE.md. The investigation findings (slider emits Number `AXValue`; UIPageControl shares `AXSlider` role but emits String; UISlider's `accessibilityValue: String?` override is ignored by iOS's serializer) remain true and useful for anyone debugging adjacent accessibility behavior. The *operational* claim that needs to change is "tap_id resolver dies whenever an AXSlider is rendered" — that's no longer true once a user has the fixed AXe.

Prefer **edit-in-place with a fix-version pivot** over wholesale deletion. The "Slider AXTree" section should still exist, still document the `AXSlider`-as-normalized-Double facts, but the resolver-poisoning paragraph should pivot to a clearly-marked "AXe ≤ 1.6.0 only" subsection, and the workarounds should demote from "recommended" to "compat workarounds for old AXe."

## Sequencing

There are two reasonable trigger points for landing these changes:

- **Trigger A — when AXe ships a tagged release containing `1a23f1cc`.** Land everything below, set the version pivot to the actual release tag, bump the skill's `plugin.json` version in the same commit.
- **Trigger B — now, with runtime version detection.** Add `_check_axe_version.sh` as part of this change, gate the foot-gun scanner and any other behavior-affecting code on the detected version, and write the SKILL.md pivots against `AXe ≥ <fix-tag>` where `<fix-tag>` is left as a TODO comment until the tag exists.

Trigger A is cleaner. Trigger B is appropriate only if there's a reason to land early — the staging tap exists but most adopters won't be on it.

## Changes to make

### 1. (HIGH) Rewrite `SKILL.md` "Slider AXTree" section

**Why.** This section is the single largest piece of skill content shaped by the upstream bug. Lines 693–721 of `SKILL.md`. The resolver-poisoning narrative dominates; the AXValue-shape facts that remain useful are buried among workarounds.

**Restructure.** Lead the section with the facts that survive the fix:

- `Slider` renders as `AXSlider`. `AXValue` is a normalized Double 0.0–1.0 — not the explicit `.accessibilityValue("...")` string set in SwiftUI. The accessibility-value modifier does NOT propagate over the inherent UISlider percentage. Recover the underlying value with `min + AXValue × (max - min)`.
- `Picker(.wheel)` renders as a UIPickerView-backed `AXSlider` with no AXUniqueId; `AXValue` is the selected index (Int, 0-based). Drive via `axe swipe` (vertical, momentum-driven, ~5–8 RT to land on a specific index).
- Driving a Slider: `axe swipe` from `frame.x + frame.width × AXValue` (current) to `frame.x + frame.width × (target-min)/(max-min)` (target). Read-back-and-correct loop averages 4 RTs to land within ±1 unit.

Then a **clearly-marked compatibility subsection** for users on `AXe ≤ 1.6.0`:

- **Compatibility note (AXe ≤ 1.6.0).** AXe's `AccessibilityElement.AXValue` was hard-typed `String?` through v1.6.0; any element emitting `AXValue` as a JSON Number (Slider, Picker(.wheel)) broke whole-tree decode and produced a session-wide `tap_id` typeMismatch error. Fixed upstream in [`cameroncooke/AXe#1a23f1cc`](https://github.com/cameroncooke/AXe/commit/1a23f1cc), shipping in AXe `<TAG>`. If you're on an older AXe and can't upgrade, apply one of the workarounds below to the affected view.
- Keep the `.accessibilityRepresentation { Text(...) }` workaround block (lines 700–711) verbatim, including the VoiceOver-regression caveat (lines 713). It's a real workaround that still works, and reading it teaches the agent something about SwiftUI accessibility composition.
- Keep the `.accessibilityHidden(true)` workaround (line 717) and `tap_xy.sh` fallback (line 718) — also still valid.
- Drop the "Until the upstream AXe fix lands" sentence from line 718; it dates the prose.

The "What does NOT work" block at line 721 (UIViewRepresentable + `accessibilityValue: String?` override; `.accessibilityAdjustableAction` doesn't restore `.adjustable` trait) can stay verbatim — those facts about iOS's serializer are independent of the AXe-side fix.

### 2. (HIGH) Demote `audit_view.sh`'s `slider_wheel_scan()`

**Why.** `scripts/audit_view.sh` lines 70–106 implement a foot-gun scan that flags every bare `Slider` and `.pickerStyle(.wheel)` in user code with: *"triggers AXe tap_id resolver poisoning when rendered (AXe v1.6.0 hard-types AXValue as String?, breaks on Float/Int from AXSlider). Wrap with .accessibilityRepresentation { Text(...) } or .accessibilityHidden(true)."* Once the user has the fixed AXe, those declarations don't trigger anything and the warning is pure noise.

**Two implementation options.**

**Option A — version-gate.** Add `scripts/_check_axe_version.sh` that parses `axe --version` and exports a comparable version. `audit_view.sh` sources it and skips `slider_wheel_scan()` when the detected version is at or past the fix. Concrete sketch:

```bash
# _check_axe_version.sh — internal helper, not a public op.
# Exports AXE_VERSION (semver) and AXE_HAS_SLIDER_FIX (0/1) into the caller's shell.
# Probes via `axe --version`; staging builds emit `0.0.0-staging.<N>` and are
# treated as ahead of every tagged release (the slider fix landed before
# staging.33, so any staging build is post-fix).
AXE_VERSION_RAW=$(axe --version 2>/dev/null || echo "0.0.0")
# … parse and set AXE_HAS_SLIDER_FIX=0 or 1 …
export AXE_VERSION AXE_HAS_SLIDER_FIX
```

Then in `audit_view.sh`:

```bash
source "$SCRIPT_DIR/_check_axe_version.sh"
# … later …
if (( AXE_HAS_SLIDER_FIX == 0 )); then
  slider_wheel_scan
fi
```

**Option B — remove.** Delete `slider_wheel_scan()` and its invocation at line 146. Simpler diff. Users still on AXe ≤ 1.6.0 lose the inline warning, but the bug surfaces the first time they run `tap_id` and the SKILL.md compatibility subsection (from change #1) carries the recovery story.

Pick A if landing under Trigger B (early, with version detection scaffolding). Pick B if landing under Trigger A (after the fix is tagged) — by then the foot-gun is rare enough that the warning's cost exceeds its value.

If Option A is taken, `_check_axe_version.sh` is also reusable in `setup_project.sh` (warn users on AXe < fix-tag at setup time) and `launch_app.sh` (surface a hint when the exit-1 stderr matches the `typeMismatch` signature on an old AXe). Worth keeping that future use in mind but not implementing it as part of this change.

### 3. (MEDIUM) Trim `SKILL.md` Picker section references

**Why.** The Picker section at line 648-661 has three places that reference the resolver-poisoning narrative:

- **Line 653**: *"May 2026 GenericApp validation initially attributed a session-wide `tap_id` resolver-poisoning error … to `.inline` Picker. May 2026 GenericApp2 isolated this to a different cause via controlled removal — the SwiftUI `Slider` control. The actual mechanism is JSON-type dependent…"*
- **Line 655**: `.wheel` Picker description includes *"Same resolver-poisoning class as `Slider` — see 'Slider AXTree' below."*
- **Line 970** (cheat sheet): *"`.wheel` renders as a no-id `AXSlider` (UIPickerView underneath) and is in the Slider-poisoning class — drive via `axe swipe`."*

**Edit.** At each location, replace the resolver-poisoning phrasing with a one-liner pointing at the "Slider AXTree" compatibility subsection from change #1. The Picker section is otherwise dense with `.menu` / `.inline` / `.segmented` / `.wheel` material that remains accurate; only the poisoning callouts need to soften.

For line 653 specifically, the historical narrative about GenericApp / GenericApp2 misattribution is useful as a record of how the bug was isolated — keep it, but reframe from "is the cause" to "was the cause through AXe v1.6.0, fixed in `<TAG>`."

### 4. (MEDIUM) Cheat-sheet entries at `SKILL.md:969-970`

**Why.** The Picker and Slider entries in the controls cheat sheet near line 969 carry the "session-wide tap_id poisoning" language as their headline framing. After change #1 lands, the cheat sheet should headline the AXValue shape and driving strategy, not a bug that's been fixed upstream.

**Edit.** Tighten both bullets to one sentence each plus a "see Slider AXTree" pointer:

- **Slider:** Renders as `AXSlider` with normalized 0–1 Double `AXValue`. Drive via `axe swipe` (read-back-and-correct, ~4 RTs to land within ±1 unit). See "Slider AXTree" above for `AXValue` recovery math, `.accessibilityRepresentation` proxy patterns, and AXe ≤ 1.6.0 compatibility.
- **`.wheel` Picker:** Renders as a no-id `AXSlider` (UIPickerView underneath); `AXValue` is the Int selected index. Drive via `axe swipe` (vertical, ~5–8 RTs). `.accessibilityIdentifier` / `.accessibilityValue` do not propagate to UIPickerView — wrap with `.accessibilityRepresentation { Text(...) }` if a stable identifier is needed.

### 5. (LOW) Update `backlog/done/bug-axe-tap-id-ipad-typemismatch.md`

**Why.** That prompt is the writeup of the original investigation that filed upstream issue #45. It currently reads as an open-bug report. It deserves a closure header for future-you.

**Edit.** Append a `## Resolution` section at the bottom:

```markdown
## Resolution

Fixed upstream in [cameroncooke/AXe#1a23f1cc](https://github.com/cameroncooke/AXe/commit/1a23f1cc) (2026-05-11), "fix(accessibility): Expose SwiftUI TabView tabs." The maintainer's fix kept `AXValue: String?` and added a defensive `init(from:)` that decodes String/Int/Double/Bool/null for every scalar field on `AccessibilityElement`, not just `AXValue`. E2E coverage for a `Slider` fixture and numeric-`AXValue` decoding landed alongside in [PR #48](https://github.com/cameroncooke/AXe/pull/48). Shipping in AXe `<TAG>`.

The originally-proposed `enum AXValueField` polymorphism and the array-vs-dict peek-the-first-byte dispatch were not adopted; the broader defensive-scalar-decode approach the maintainer chose is a superset of the former and the latter is unaffected for the slider case.
```

Do **not** delete the rest of the prompt; it documents the investigation path and shaped how the skill's Slider section was written.

### 6. (LOW — only if landing under Trigger A) Bump `.claude-plugin/plugin.json` version

When the upstream fix is tagged and changes #1–#5 land in one PR, bump the skill's `version` field. Per repo convention, recent releases have been 0.2.0 → 0.2.1; pick 0.2.2 or 0.3.0 depending on whether you want to signal "minor follow-on" or "material reduction in friction surface."

## Files touched

- `skills/ios-build-verify/SKILL.md` — sections "Slider AXTree" (~693–721), Picker `.wheel` mentions at ~653–655, controls cheat sheet at ~969–970.
- `skills/ios-build-verify/scripts/audit_view.sh` — `slider_wheel_scan()` lines 70–106 and invocation at line 146.
- `skills/ios-build-verify/scripts/_check_axe_version.sh` — new file, only if Option A in change #2 is chosen.
- `backlog/done/bug-axe-tap-id-ipad-typemismatch.md` — append `## Resolution`.
- `.claude-plugin/plugin.json` — version bump if landing under Trigger A.

## Verification

After landing the changes:

- `bash skills/ios-build-verify/scripts/audit_view.sh <fixture-with-bare-Slider>` against a Slider declaration should: (a) emit no warning on fixed AXe; (b) still emit the warning on AXe ≤ 1.6.0 if Option A was chosen.
- `grep -n "session-wide" skills/ios-build-verify/SKILL.md` should return only matches inside the compatibility subsection — no headline references.
- `grep -n "resolver poisoning\|resolver-poisoning" skills/ios-build-verify/SKILL.md` should return zero matches outside the compatibility subsection and the `## Resolution`-flagged prompts.
- `smoke_test.sh` should still pass end-to-end on a Slider-containing fixture app once the user is on fixed AXe.

## Non-goals

- **Do not** delete or fold the May 2026 GenericApp / GenericApp2 investigation references. They're load-bearing record-of-evidence for future debugging of adjacent accessibility behavior.
- **Do not** remove the `.accessibilityRepresentation { Text(...) }` workaround documentation. It remains a useful pattern for adopters who need a stable string `AXValue` on `.wheel` Pickers (which never had an AXUniqueId regardless of the AXe bug) and for adopters on older AXe.
- **Do not** open a new upstream PR adding the array-vs-dict peek-byte dispatch unless an independent shape-mismatch case surfaces. The current behavior is correct for the slider case; the peek-byte change is a diagnostic-quality improvement, not a correctness fix, and merits its own narrative if filed.
