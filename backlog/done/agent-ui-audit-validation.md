# Implementation prompt: Agent-driven UI-audit validation findings

## Context

You are working in `~/Desktop/workspace/ios-build-verify` — the source repo for the `ios-build-verify` Claude Code skill. The skill is published at `https://github.com/vermont42/ios-build-verify`.

This prompt was written after a **May 5 2026 second Konjugieren session** that exercised the skill in a different mode than the May 2026 Konjugieren validation captured in `backlog/setup-project-rollup-heuristic.md`. That earlier session validated build-and-launch lifecycle plus `set_value.sh` semantics. This session used the skill to drive an **agent-led UI design audit**: launch the app, drive every main screen, capture screenshots, drive into detail screens, capture sub-states, and synthesize a fresh design-improvement document (`docs/ui-audit-2.md` in the Konjugieren repo). The use case is "agent walks the app like a designer reviewing a spec," not "agent edits code and verifies a fixed assertion."

The friction surfaced by this use case is different from the build-and-fix loop's friction. Specifically: agents driving an audit make many small, exploratory taps and screenshots; tap many elements they did not author; type into fields that may not have identifiers; and need to navigate UI patterns (page-style TabViews, hidden modal gating from review prompts) that the build-and-fix loop typically does not exercise.

The session was Claude Code (CLI) running Claude Opus 4.7 — the validated configuration per SKILL.md's "Validated configuration" section. All friction below is reproducible on that configuration. Behavior on other models or harnesses is unknown.

## Design principle to apply

**SKILL.md line 35: "Mechanize prose recipes."** Where SKILL.md tells the agent to compose a multi-step workflow or read prose to recover from a failure mode, that recipe is a candidate for replacement by a shipped script with classifying error output. New skill investment should preferentially convert prose recipes into scripts rather than add new prose.

The single biggest force multiplier suggested below is purely documentary (Change #1 — coordinate-space note) — that's a straightforward exception to the principle, since the failure mode is "agent never knew the rule existed" and one paragraph in the right place fixes it.

## Changes to make

### 1. (HIGH, near-zero cost) Document the coordinate space explicitly in SKILL.md

**Why.** The agent driving this session repeatedly mixed pixel coordinates (from `simctl io … screenshot`) with logical-point coordinates (which `axe tap` / `axe swipe` / `axe describe-ui` consume). Concretely: the agent screenshotted Konjugieren on iPhone 17, observed the "Dismiss" button at pixel `(1024, 184)`, called `axe tap -x 1024 -y 184`, and tapped well off the visible screen — iPhone 17's logical viewport is roughly `393 × 852` points, so `(1024, 184)` is far outside it. Recovery required `axe describe-ui` + JSON walk to find the actual logical-point frame `{x: 326.67, y: 62, w: 59.33, h: 20.33}`. The mistake cost roughly 10 minutes of session time and several wasted tool calls.

The rule is simple but **not currently stated anywhere** in SKILL.md. Adopters learn it by failure.

**Implementation outline.**

Add a short section near the top of the verify-half operation surface (between the "Dependencies" and "Common first-real-app friction" sections, or as a new entry inside "Common first-real-app friction"). Suggested wording:

```markdown
### Coordinate space: logical points, not pixels

`axe tap`, `axe swipe`, and `axe describe-ui` consume **logical points**, not pixels.
`xcrun simctl io <UDID> screenshot <path>` writes a PNG in **pixels** at the device's
native scale (3× on retina iPhones). Mixing them produces taps that land far
off-screen and look like silent failures.

To translate a coordinate read off a screenshot to an axe tap, divide pixel
coordinates by the device's scale factor. iPhone 17 / 17 Pro / 17 Plus are 3×.

To skip the math entirely, prefer `describe_ui.sh` to find the element's frame
in logical points directly. Example workflow for finding a button by label:

  axe describe-ui --udid "$UDID" | python3 -c "
import json, sys
data = json.load(sys.stdin)
def walk(node):
    if isinstance(node, dict):
        if node.get('AXLabel') == 'Dismiss' and node.get('type') == 'Button':
            print(node.get('frame'))
        for v in node.values(): walk(v)
    elif isinstance(node, list):
        for v in node: walk(v)
walk(data)
"

The frame's x/y is already in logical points; tap (frame.x + frame.w/2, frame.y + frame.h/2).
```

The sample Python is already what the validating agent ended up writing; lifting it into SKILL.md prevents the next agent from re-deriving it.

**Pairs naturally with** `describe_ui.sh --point x,y`, shipped at commit `0ee193e` (next-iteration-prompt.md change #1). The example block above can now shrink to use `describe_ui.sh --point <x>,<y>` directly when a candidate coordinate is already in hand; keep the python walk as the AXLabel-search recipe for the case where the agent has only a label and needs to find the coordinate.

**CLAUDE.md updates.** Commit `0ee193e` already updated the "Logical points, not pixels" bullet to point at `describe_ui.sh --point` as the recommended way to read a logical-point frame; the cross-reference to this prompt for the sample JSON walk is still in place. After the SKILL.md section lands, redirect that cross-reference to SKILL.md and shorten the bullet further.

### 2. (HIGH) Make `screenshot.sh` self-correcting on path-shaped arguments

**Why.** `screenshot.sh <slug>` takes a context slug — e.g., `screenshot.sh quiz-active` produces `docs/screenshots/<timestamp>-quiz-active.png`. The current usage line is `usage: screenshot.sh <context-slug>`. The validating agent, fluent in shell idioms but not in this script's specific contract, called `screenshot.sh docs/screenshots/onboarding-2.png` thinking the argument was an output path. The script obediently used that whole string as the slug and produced `docs/screenshots/<timestamp>-docs/screenshots/onboarding-2.png.png` — a nested directory. The agent worked around by switching to `xcrun simctl io … screenshot <abs-path>` for the rest of the session, abandoning the wrapper.

This is **friction at scale**: once an agent abandons a wrapper, every subsequent screenshot bypasses skill-internal logging, telemetry, and standard placement. The ergonomic slip cascades.

**Implementation outline.**

Add a guard at the top of `screenshot.sh` after `CONTEXT="$1"`:

```bash
# Reject path-shaped arguments. The script generates a path internally
# from <slug>; an argument containing a slash or ending in .png is almost
# always a misuse where the caller thought they were specifying output path.
if [[ "$CONTEXT" == */* || "$CONTEXT" == *.png ]]; then
  echo "error: argument '$CONTEXT' looks like a path, not a slug." >&2
  echo "  screenshot.sh takes a context slug; output is auto-named:" >&2
  echo "    docs/screenshots/<timestamp>-<slug>.png" >&2
  echo "  example: screenshot.sh quiz-active" >&2
  echo "  to override path entirely, use: xcrun simctl io \$UDID screenshot <abs-path>" >&2
  exit 2
fi
```

The error message names the post-state ("looks like a path"), states the contract, gives an example, and points at the escape hatch — the same shape SKILL.md's "Errors as state probes" principle prescribes for the existing `read_value.sh` / `verify_value.sh` / `set_value.sh` exit-4 hint.

**SKILL.md updates.** Add one bullet to the `screenshot.sh` description noting that the argument is a slug (output path is auto-generated) — currently the SKILL.md description doesn't mention the slug-vs-path distinction.

**CLAUDE.md updates.** The "`screenshot.sh` takes a slug, not a path" bullet currently describes the failure mode as a nested-filename mess. After the guard lands, shorten the bullet to note the script now refuses path-shaped arguments with a classifying error.

### 3. (HIGH) Address typing into unidentified TextFields

**Why.** `set_value.sh <id> <text>` mechanizes typing into a field with a known accessibility identifier. The script taps the identifier, clears with Cmd+A, calls `axe type "$TEXT"`, and read-backs to verify. This works perfectly when the field has `.accessibilityIdentifier()`.

The validating agent wanted to submit a wrong answer to Konjugieren's quiz to capture the post-incorrect feedback state. The Quiz `TextField` (in `Konjugieren/Views/QuizView.swift:172-218`) has `.focused`, `.accessibilityFocused`, `.accessibilityHint`, but **no `.accessibilityIdentifier()`**. So `set_value.sh` was not usable. The agent then tried `xcrun simctl io <UDID> type "xxx"` — this is not a real subcommand and produced no output but also no error (silent no-op). The agent never discovered `axe type "$TEXT"` as a primitive because it's not surfaced anywhere outside `set_value.sh`'s internals.

Two gaps:
1. **Discoverability.** `axe type` is a real, useful primitive; the agent shouldn't have to read another script's source to find it.
2. **Coordinate-driven typing.** When a field has no accessibility identifier, the only reliable focus mechanism is a coordinate tap. There is currently no script that wraps "tap-to-focus + type."

**Implementation outline.**

Ship a new `type_text.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 2; }
source "$CONFIG"

# usage:
#   type_text.sh --id <accessibility-identifier> <text>
#   type_text.sh --xy <x>,<y> <text>
# The --id form is a thin alias for set_value.sh.
# The --xy form taps to focus, types, and does NOT verify (no read-back path
# without an identifier). Caller is responsible for follow-up verification.

[[ $# -ge 3 ]] || { echo "usage: type_text.sh (--id <id> | --xy x,y) <text>" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"

case "$1" in
  --id)
    exec "$SCRIPT_DIR/set_value.sh" "$2" "$3"
    ;;
  --xy)
    IFS=',' read -r X Y <<< "$2"
    "$SCRIPT_DIR/tap_xy.sh" "$X" "$Y" >/dev/null
    sleep 0.2
    axe key-combo --modifiers 227 --key 4 --udid "$UDID" >/dev/null  # Cmd+A to clear
    axe type "$3" --udid "$UDID" >/dev/null
    echo "typed: '$3' at ($X,$Y) — no read-back verification on coordinate-driven typing"
    ;;
  *)
    echo "error: first arg must be --id or --xy, got '$1'" >&2
    exit 2
    ;;
esac
```

The `--xy` path explicitly notes "no read-back verification" so callers don't expect the same guarantees `set_value.sh` provides. This is the principled limitation: without an identifier, the post-state is unreadable.

**Pairs naturally with** `tap_xy.sh --verify-target`, shipped at commit `0ee193e` (next-iteration-prompt.md change #2). Two compositions worth noting: (a) the agent runs `tap_xy.sh --verify-target` first to confirm the coordinate hits a `TextField`, then `type_text.sh --xy`; or (b) `type_text.sh --xy` itself accepts an optional `--verify-target <axlabel>` (and `--verify-role TextField`) and threads it through `tap_xy.sh` so the coordinate-driven typing path inherits the same AXLabel/role guard before focus. (b) is a small implementation lift on top of the outline above and avoids the agent having to compose two scripts manually.

**SKILL.md updates.** Add a short section "Typing text into a field." It should cover (a) when to use `set_value.sh` (field has identifier), (b) when to use `type_text.sh --xy` (field has no identifier, post-state must be assumed), (c) the `axe type` primitive itself for advanced cases. Note the "no `.accessibilityIdentifier()`" failure mode explicitly so future agents pattern-match it.

**CLAUDE.md updates.** The "`set_value.sh` requires an accessibility identifier" bullet currently says "There is no shipped wrapper for tap-to-focus + type." After `type_text.sh` lands, replace with a pointer to `type_text.sh --xy <x>,<y> <text>` for unidentified fields, noting that the `--xy` path has no read-back verification so callers must assert post-state separately.

### 4. (MEDIUM) Document the iOS 26 SwiftUI `TabView(.page)` swipe limitation

**Why.** The validating agent attempted multiple times to `axe swipe` through a `TabView(.page)`-styled `OnboardingView` to capture each onboarding page. Every attempt failed silently — the swipe gesture executed at the AXe layer but did not trigger the page coordinator's velocity threshold. Page-indicator dots are not exposed as hit-testable accessibility elements either, so tapping the second dot did nothing. The agent ultimately read source code (`OnboardingView.swift`) to understand the page structure and abandoned the runtime capture.

This is a **real iOS 26 SwiftUI limitation, not a bug in `axe swipe`** — but the failure mode is opaque to a fresh agent. They will try several swipe parameters and conclude their coordinates are wrong, when in fact no parameters would succeed.

**Implementation outline.**

Two parts:

a. **SKILL.md note.** Add to "Common first-real-app friction" (currently 6 items) a new item:

```markdown
7. **iOS 26 SwiftUI TabView(.page) gesture-injection wall.** Apps with onboarding
   or any other paged TabView (.tabViewStyle(.page)) cannot be advanced via
   `axe swipe`: the gesture executes but the page coordinator's velocity
   threshold rejects it. Page-indicator dots (.indexViewStyle) are not
   hit-testable as accessibility elements either. Recovery: read the source
   to understand the page sequence and the dismiss/skip mechanism, then
   either dismiss the modal entirely (if you only need the post-modal state)
   or drive page advancement programmatically by setting the bound state
   that `selection: $currentPage` reads. The validating session for this
   skill (May 5 2026 Konjugieren UI audit) hit this on `OnboardingView.swift`
   and ended up reading source for design inspection rather than capturing
   per-page screenshots.
```

b. **Optional: ship `swipe_page_tabview.sh` that fails fast with this hint.** A script that runs the most-likely-to-succeed swipe parameters, then describe-uis to detect whether the page changed, and if not exits with a hint pointing at the SKILL.md section above:

```bash
swipe_page_tabview.sh
# Performs a wide horizontal swipe with longer duration.
# After the swipe, samples the AXTree for any visible state change.
# If no change detected, exits with classifying hint:
#   error: TabView(.page) swipe did not advance the page.
#   hint: this is a known iOS 26 SwiftUI limitation. See SKILL.md
#         "Common first-real-app friction" item 7 for the workaround.
```

The script would be small; its value is in the classifying error, not the swipe attempt itself.

**CLAUDE.md updates.** The "iOS 26 SwiftUI `TabView(.page)` cannot be advanced by `axe swipe`" bullet currently stands alone with the recovery options inline. After the SKILL.md "Common first-real-app friction" item #7 lands, shorten the CLAUDE.md bullet to cross-reference SKILL.md.

### 5. (MEDIUM) Ship `verify_label_visible.sh` for declarative assertions

**Why.** The current verify-half scripts (`verify_screen_loaded.sh`, `verify_value.sh`, `verify_segment.sh`) each cover specific shapes of assertion. None covers the most generic shape: "is an element with this AXLabel present in the AXTree right now?" An audit-driving agent constantly needs this — "did Settings render?", "did the modal dismiss?", "did the toast appear?" — and currently composes it ad-hoc via `axe describe-ui | grep`.

**Implementation outline.**

```bash
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
    --role) ROLE="$2"; shift 2 ;;
    *) echo "error: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_resolve_udid.sh"

axe describe-ui --udid "$UDID" | python3 -c "
import json, os, sys
target_label = os.environ['LABEL']
target_role = os.environ.get('ROLE', '')
data = json.load(sys.stdin)
found = False
def walk(node):
    global found
    if isinstance(node, dict):
        if node.get('AXLabel') == target_label and (not target_role or node.get('type') == target_role):
            found = True
        for v in node.values(): walk(v)
    elif isinstance(node, list):
        for v in node: walk(v)
walk(data)
sys.exit(0 if found else 4)
" LABEL="$LABEL" ROLE="$ROLE"

case $? in
  0) echo "visible: '$LABEL'${ROLE:+ ($ROLE)}"; exit 0 ;;
  4) echo "error: '$LABEL'${ROLE:+ ($ROLE)} not present in AXTree" >&2; exit 4 ;;
  *) exit 1 ;;
esac
```

Exit 4 (the existing "AXTree state probe failure" code) on label-not-found classifies the post-state in line with the `Errors as state probes` principle.

**SKILL.md updates.** Add to the verify-ops list. Cite explicit use cases: "after `tap_xy.sh` to confirm the screen actually changed; after launch to confirm a screen-specific element rendered (when `FIRST_SCREEN_ID` is too generic to distinguish post-launch from a deep nav state)."

**CLAUDE.md updates.** Optional. After this lands, consider naming `verify_label_visible.sh` in the runtime-contract section as the canonical "is this label visible?" probe so fresh agents find it before composing `axe describe-ui | grep` ad hoc.

### 6. (LOWER) First-real-app smoke test

**Why.** SKILL.md's "Common first-real-app friction" lists the predictable failure modes a new adopter will hit. A user reading SKILL.md cold has to absorb the list and apply each item to their app preemptively. Most won't — they'll dive in, hit the first issue, and grep SKILL.md for a hint. Mechanizing the friction-discovery itself shifts the cost from the user to the script.

**Implementation outline.**

Ship `smoke_test.sh` that runs a canonical sequence and reports per-step outcomes:

```bash
smoke_test.sh
# 1. build_app.sh                                (validates build env)
# 2. launch_app.sh                               (validates FIRST_SCREEN_ID, ONBOARDING_DISMISS_LABEL)
# 3. screenshot.sh smoke-launch                  (validates screenshot path)
# 4. for each tab in MAIN_TABS:
#    - tap_tab.sh <tab>
#    - screenshot.sh smoke-tab-<name>
#    - verify_label_visible.sh <expected element>   (requires per-tab anchor in config)
# 5. terminate_app.sh
# Output:
#   ✓ build
#   ✓ launch (FIRST_SCREEN_ID seen in 4.2s)
#   ✓ screenshot
#   ✓ tab verbs (verb_browse_anchor visible)
#   ✓ tab families (...)
#   ✗ tab quiz (expected 'Quiz' nav title; found nothing) — see SKILL.md "Identifier rollup"
```

Per-tab anchors require a new config field — `MAIN_TAB_ANCHORS=(...)` parallel to `MAIN_TABS_COORDS`. The `setup_project.sh` colloquy could optionally collect them, or skip them and have `smoke_test.sh` fall back to "screen changed" verification by sampling AXTree before/after.

The first run on a new project does the calibration the human would otherwise do across multiple sessions — every step that fails surfaces a hint pointing at the SKILL.md section that classifies the failure mode.

**Pairs naturally with** Change #5: each smoke-test step uses `verify_label_visible.sh` for assertion, so #5 is a soft prerequisite.

**CLAUDE.md updates.** Optional. After this lands, consider adding a "first-real-app smoke test" pointer to the runtime-contract section so a fresh agent runs the canonical sequence before composing ad-hoc validation flows.

### 7. (LOWER) Document `axe key` keycode form

**Why.** The validating agent tried `axe key --keycode 40` (return key) and got "Unknown option '--keycode'." Switching to `axe key 40` worked. Minor friction, but unfamiliar agents hit it.

**Implementation outline.** One line in SKILL.md:

```markdown
**Key dispatch.** `axe key <keycode>` (positional argument, not a `--keycode` flag).
Common keycodes: 40 = return, 42 = backspace, 41 = escape. Modifiers go via
`axe key-combo --modifiers <mask> --key <code>` — see set_value.sh for the
Cmd+A example (modifier mask 227, key 4).
```

The keycodes are HID usage codes; one example surface in SKILL.md prevents the next agent from grepping `axe --help` blindly.

**CLAUDE.md updates.** The "`axe key` uses a positional keycode" bullet currently carries the keycodes (40, 42, 41) and Cmd+A example inline. After the SKILL.md note lands, shorten the CLAUDE.md bullet to cross-reference SKILL.md instead of duplicating the keycodes.

## Independence and ordering

All seven changes are independent — implement any one without the others. Recommended ordering if doing multiple:

1. **#1** (coord-space doc) — minutes; pays off immediately.
2. **#2** (screenshot.sh guard) — minutes; isolates a current usability cliff.
3. **#5** (verify_label_visible.sh) — small new script; foundation for #6.
4. **#6** (smoke_test.sh) — uses #5; high payoff on first runs.
5. **#3** (type_text.sh) — small new script; fills the unidentified-field gap.
6. **#4** (TabView(.page) doc + optional script) — short doc + optional small script.
7. **#7** (axe key doc) — one paragraph; pure cleanup.

## What this prompt does NOT recommend

- **Replacing `screenshot.sh`'s slug API with a path API.** Slug-based naming with auto-timestamps is the right default — it produces consistent ordering, prevents collisions, and matches the convention that screenshots are diagnostics, not artifacts. The fix in #2 is a guard, not a contract change.
- **Adding swipe-by-velocity-threshold workarounds for TabView(.page).** Inspection suggests there is no reliable workaround at the AXe layer for iOS 26 page-style TabView gesture injection. Documenting the limitation (Change #4a) is the right move; chasing the gesture parameter space (Change #4b) is best-effort and potentially fragile.
- **Forcing all SwiftUI TextFields in adopting apps to add `.accessibilityIdentifier()`.** That's an opinion this skill should not impose. Change #3 lets coordinate-driven typing work without imposing the constraint.

## Validation note

This prompt was written by Claude Opus 4.7 in Claude Code (CLI) — the validated configuration. The same model in the same harness drove the Konjugieren audit session that surfaced every issue above. Reproduction:

```bash
cd ~/Desktop/workspace/Konjugieren
# Build, launch, drive UI, capture screenshots — see docs/ui-audit-2.md context section
# for the full driver pattern. Specific friction points reproduce as:
#   - Change #1: any axe tap that uses pixel coordinates from simctl screenshots.
#   - Change #2: screenshot.sh docs/screenshots/foo.png
#   - Change #3: any TextField in QuizView (no accessibility identifier on iOS 26).
#   - Change #4: any axe swipe attempt against OnboardingView.swift's TabView(.page).
```

The Konjugieren audit also produced `docs/ui-audit-2.md` in that repo — a separate artifact, not relevant to this skill, but referenced here as evidence the session ran end-to-end and shipped real output.

## Resolution

All seven changes shipped at commit `ae4694a` ("Mechanize friction from May 5 Konjugieren UI-audit validation"):

- **#1 Coordinate-space note.** `SKILL.md` gained a "Coordinate space: logical points, not pixels" section. CLAUDE.md's matching bullet shortened to cross-reference it.
- **#2 `screenshot.sh` path-shaped guard.** The script now rejects arguments containing `/` or ending in `.png` with a classifying error message pointing at `xcrun simctl io <UDID> screenshot <abs-path>` as the escape hatch for explicit output paths.
- **#3 `type_text.sh`.** Shipped with `--id` (aliasing `set_value.sh`) and `--xy` (coordinate-driven, no read-back) modes. The `--xy` path optionally accepts `--verify-target <axlabel>` and `--verify-role <role>` (composition (b) from the prompt) so coordinate-driven typing inherits the same AXLabel/role guard `tap_xy.sh --verify-target` provides.
- **#4 `swipe_page_tabview.sh` + SKILL.md item #7.** The "Common first-real-app friction" list gained the iOS 26 SwiftUI `TabView(.page)` gesture-injection-wall note. `swipe_page_tabview.sh` ships as the fail-fast diagnostic — swipes wide and slow, fingerprints the AXTree before/after, exits 7 with the SKILL.md cross-reference when unchanged.
- **#5 `verify_label_visible.sh`.** Shipped with optional `--role` disambiguation; exit 4 on label-not-found follows the existing AXTree-state-probe convention.
- **#6 `smoke_test.sh`.** Canonical build → launch → screenshot → per-tab tap+screenshot+assertion → terminate harness with per-step ✓/✗ output. Now documented as the first-real-app probe.
- **#7 `axe key` keycode doc.** `SKILL.md` gained a "Key dispatch" section covering the positional-keycode form, common keycodes (40 = return, 42 = backspace, 41 = escape, 43 = tab), and `axe key-combo --modifiers <mask> --key <code>` syntax.

The 0.2.x release line was cut after this batch landed.
