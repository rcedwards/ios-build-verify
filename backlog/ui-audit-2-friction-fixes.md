# Implementation prompt: ios-build-verify friction fixes from a Konjugieren UI-audit-2 session

## Context

You are working in `~/Desktop/workspace/ios-build-verify` — the source repo for the `ios-build-verify` Claude Code skill. The skill is published at `https://github.com/vermont42/ios-build-verify`.

This prompt was written after a 2026-05-06 Konjugieren UI-audit-2 session that landed three audit items (#9, #6, #11) at commit `778e105`. The verify half of the skill drove the simulator throughout: launch, tap-to-tab, tap-by-label, vertical scrolling through `VerbView`, and screenshot capture for A/B comparison. Four friction points surfaced. Each has a small, well-scoped fix.

The session's source repo (Konjugieren) was at `~/Desktop/workspace/Konjugieren` and the simulator was the iPhone 17 with UDID `5EBCB956-F69C-4659-980E-207D9F4C1FCF` running iOS 26.3 — relevant for reproducing the friction below.

## Design principle to apply

**SKILL.md's "Mechanize prose recipes" principle still governs.** Two of the four changes below convert a prose pattern ("swipe N times until target visible") or a workaround ("cd back to project root before invoking script") into either a shipped script or a more robust script. The third makes existing matching more flexible. The fourth tightens a script's exit-code contract for chainability.

## Changes to make

### 1. (HIGH) Resolve config-relative paths from git toplevel, not cwd

**Why.** Every script that calls `source "$(pwd)/.claude/ios-build-verify.config.sh"` is fragile to cwd. Claude Code's `Bash` tool persists working directory across calls, so a single `cd docs/screenshots && mv ... && rm ...` cleanup chain (a perfectly reasonable thing to do mid-session) leaves the cwd at `docs/screenshots`. A subsequent `screenshot.sh some-slug` invocation then fails with:

```
error: /Users/josh/Desktop/workspace/Konjugieren/docs/screenshots/.claude/ios-build-verify.config.sh not found.
```

The error is diagnostic, but the failure mode is invisible until it happens — nothing in the script signature or SKILL.md surfaces the cwd contract. Claude Code's session-prompt guidance ("maintain your current working directory throughout the session by using absolute paths and avoiding usage of `cd`") reduces but doesn't eliminate the failure: any non-Claude user invoking the script from a subdirectory hits the same wall, and Claude itself sometimes legitimately needs to `cd` for batched file operations.

**Implementation outline.** Replace the cwd lookup with a git-toplevel lookup, falling back to a walk-up search if git isn't available:

```bash
# Replace this pattern (currently in build_app.sh, run_tests.sh, screenshot.sh,
# launch_app.sh, and others — grep for `\.claude/ios-build-verify\.config\.sh`):
CONFIG="$(pwd)/.claude/ios-build-verify.config.sh"

# With a resolver:
CONFIG="$(_find_project_config)"

# Where _find_project_config() lives in a new helper, e.g. scripts/_find_config.sh:
_find_project_config() {
  # Prefer git toplevel (handles invocation from any subdirectory of the repo).
  if command -v git >/dev/null 2>&1; then
    local toplevel
    toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [[ -n "$toplevel" && -f "$toplevel/.claude/ios-build-verify.config.sh" ]]; then
      echo "$toplevel/.claude/ios-build-verify.config.sh"
      return 0
    fi
  fi
  # Fall back to walking up from cwd (handles non-git checkouts).
  local dir="$(pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/.claude/ios-build-verify.config.sh" ]]; then
      echo "$dir/.claude/ios-build-verify.config.sh"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}
```

If the resolver returns empty, exit 2 with the original message *plus* a `hint:` line: "if your project is not a git repo, invoke from the project root (the directory containing `.claude/ios-build-verify.config.sh`) or symlink the config to your shell's working directory."

**Scripts to update.** Grep for the cwd pattern and update each call site:

```bash
grep -rn '\.claude/ios-build-verify\.config\.sh' scripts/
```

Likely list (verify): `build_app.sh`, `run_tests.sh`, `launch_app.sh`, `screenshot.sh`, `tap_label.sh`, `tap_id.sh`, `tap_xy.sh`, `tap_tab.sh`, `terminate_app.sh`, `describe_ui.sh`, `audit_view.sh`, `verify_*.sh`, `read_value.sh`, `set_value.sh`, `dismiss_onboarding.sh`, `swipe_page_tabview.sh`, `type_text.sh`. Use `_find_config.sh` as the single source of truth.

**SKILL.md updates.** Add a note under the "Per-project config" section explaining that scripts now resolve `.claude/ios-build-verify.config.sh` via git toplevel (with cwd-walk fallback for non-git projects), so scripts can be invoked from any subdirectory of the project. The previous cwd contract should be removed from any place it's currently documented.

### 2. (HIGH) Ship `swipe_vertical.sh` (and optionally `scroll_to_label.sh`)

**Why.** During Konjugieren UI-audit-2, capturing the post-#6 etymology screenshot in `VerbView` for `sein` required scrolling past 14 conjugation cards (`Perfektpartizip`, `Präsenspartizip`, `Präsens Indikativ`, `Präteritum Indikativ`, `Präsens Konjunktiv I`, `Präteritum Konjunktiv II`, `Imperativ`, `Perfekt Indikativ`, `Perfekt Konjunktiv I`, `Plusquamperfekt Indikativ`, `Plusquamperfekt Konjunktiv II`, `Futur Indikativ`, `Futur Konjunktiv I`, `Futur Konjunktiv II`) before the etymology card became visible. The skill ships `swipe_page_tabview.sh` for paged TabView, but nothing for plain vertical scrolling. The agent had to invoke `axe swipe --start-x 200 --start-y 700 --end-x 200 --end-y 100 --duration 0.5 --udid $UDID` directly — UDID resolution, gesture choreography, and iteration loop all composed inline.

The result was four "attempt" screenshots before landing the right scroll position, plus manual `mv` and `rm` to clean up the rejects. End-to-end this added six tool calls beyond what the actual capture needed.

**Implementation outline.**

```
usage: swipe_vertical.sh [--direction up|down] [--amount N] [--duration S]

  Scroll the visible viewport with a vertical swipe. UDID resolution,
  iPhone 17 viewport defaults, and direction-to-gesture translation
  are handled internally.

  --direction  up | down (default: down)
  --amount     pixels to scroll (default: 500)
  --duration   gesture duration in seconds (default: 0.5)
```

Internally:
- `down` translates to a swipe from (200, 700) to (200, 700 - amount). (i.e., finger moves up to scroll content down).
- `up` translates to (200, 200) to (200, 200 + amount).
- Use the same iPhone 17 viewport defaults already in `swipe_page_tabview.sh`; allow override flags for non-standard viewport sizes.
- Like `swipe_page_tabview.sh`, fingerprint the AXTree before/after; on no change, exit non-zero with a hint pointing at "scroll target was at the edge of the scrollable content."

**Optional companion: `scroll_to_label.sh <axlabel>`.** Loop `axe describe-ui` to find whether the target label is on-screen (a label that's in the AXTree but not in the visible frame range will return its `AXFrame` outside the viewport — capture that). Walk vertical swipes in the appropriate direction until the label's `AXFrame` lands inside the visible viewport, or N iterations elapse without progress. This converts the "screenshot, eyeball, swipe, screenshot, eyeball" loop into one call. Use the `swipe_vertical.sh` primitive internally.

**SKILL.md updates.** Add to the operation surface in SKILL.md alongside the existing tap/screenshot/describe ops. The "Common verify-half friction" section should call out: "Verifying content past the visible viewport requires `swipe_vertical.sh` (single swipe) or `scroll_to_label.sh` (loop until visible). Direct `axe swipe` invocation is fine but loses UDID resolution and viewport defaults."

**CLAUDE.md updates (in the consuming project).** The skill's `setup_project.sh` should mention these scripts in the emitted CLAUDE.md snippet's "operation surface" line so consuming projects pick up the new vocabulary automatically.

### 3. (MEDIUM) Add `--contains <substring>` to `tap_label.sh`

**Why.** SwiftUI lists with `.accessibilityElement(children: .combine)` produce composed labels. In Konjugieren's `FamilyBrowseView`, the tap target for the Separable family had `AXLabel`:

```
Separable, Prefix detaches in main clauses. Like "come up" or "get down"., 212
```

That's the family name + family description + verb count, comma-joined. To tap it, the agent had to:

1. Run `describe_ui.sh` to dump the full AXTree.
2. Grep for `Separable` to find the full composed label.
3. Pass the entire string to `tap_label.sh` (with embedded double-quotes that need careful shell escaping).

A `tap_label.sh "Separable"` first-attempt fails with:

```
error: No accessibility element matched --label 'Separable'. ... prefer --id when available.
```

The error correctly suggests `--id`, but `--id` isn't always available (Konjugieren's family rows don't carry custom identifiers). Substring match is the natural middle ground.

**Implementation outline.**

```
tap_label.sh "Separable" --contains
# Or, more explicitly:
tap_label.sh --contains "Separable"
```

Pre-query: `axe describe-ui` (or `--point` for a region-narrowed query) and walk the AXTree finding nodes whose `AXLabel` *contains* the substring. If exactly one match, tap it. If zero matches, error as today. If multiple matches, list them with their `AXLabel` and `AXFrame`, refuse to tap, exit non-zero with a "specify a more unique substring or use --label for exact match" hint.

**Don't break existing behavior.** Without `--contains`, `tap_label.sh` should continue to require exact match (the current contract). The flag is opt-in.

**Pairs naturally with `--verify-target` from the prior next-iteration prompt.** A `--contains` match plus a `--verify-target "expected unique landmark"` post-tap check gives the agent the same guard against fuzzy-target misfires that `tap_xy.sh --verify-target` provides for coordinate taps.

**Exit codes.** Add a new "ambiguous match" code distinct from "no match." Document in SKILL.md.

**SKILL.md updates.** Add a paragraph under the `tap_label.sh` operation explaining the `--contains` flag, when to prefer it (composed labels from `accessibilityElement(children: .combine)` lists), and when to avoid it (when the substring might match multiple unrelated elements — e.g., common words like "Settings" that appear in nav titles and section headings).

### 4. (LOWER) `terminate_app.sh` should exit 0 when nothing is running

**Why.** `terminate_app.sh && launch_app.sh` is the natural chain for "make sure I'm starting from a clean slate." But `terminate_app.sh` exits 3 with the simctl error:

```
An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):
Simulator device failed to terminate biz.joshadams.Konjugieren.
found nothing to terminate
```

…when the app is already not running. That breaks the `&&` chain — `launch_app.sh` never executes. The agent's correction is to drop the chain and just call `launch_app.sh` directly, which works but loses the "ensure clean state" guarantee.

The "found nothing to terminate" condition is *not* a failure — it's the desired post-state. `terminate_app.sh` should detect this specific simctl error and exit 0.

**Implementation outline.**

```bash
# In terminate_app.sh, capture simctl's stderr:
output="$(xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>&1)"
status=$?
if [[ $status -ne 0 ]]; then
  if echo "$output" | grep -q 'found nothing to terminate'; then
    echo "$BUNDLE_ID was not running; nothing to terminate (treating as success)."
    exit 0
  fi
  echo "$output" >&2
  exit $status
fi
```

**Alternative: opt-in flag.** If preserving the strict exit-non-zero behavior matters for some workflow, add `--ok-if-not-running` instead and have callers opt in. But the natural use case for `terminate_app.sh` is "I want this app stopped" — and "it was already stopped" satisfies that intent. Default-to-success is the better contract.

**SKILL.md updates.** Document the new exit-code semantics under `terminate_app.sh`'s entry. If implementing the opt-in flag instead, note the flag and recommend it for the chained-with-launch use case.

## Verification

For each change, the verification path is:

1. **Build the skill's smoke harness.** `scripts/smoke_test.sh` (existing) — run it after each change to confirm no regression in the operation surface.
2. **Reproduce the original friction in a target project.** Konjugieren is a known-good fit; clone fresh, run `setup_project.sh`, and exercise the affected scripts from a non-root subdirectory (#1), in a screen requiring vertical scroll (#2), with a composed-label list (#3), and with a chained terminate+launch (#4).
3. **Update SKILL.md and CLAUDE.md emission in `setup_project.sh`** so consuming projects pick up the new vocabulary on next setup. Verify the emission with `bash scripts/setup_project.sh --print` (or whatever the existing dry-run flag is).
4. **Bump the skill version** and update `~/.claude/plugins/marketplaces/ios-build-verify/...` install location reference if relevant. The Konjugieren CLAUDE.md captures the version-rotation pattern: `export IBV_SCRIPTS=$(dirname "$(find ~/.claude -path '*ios-build-verify*' -name build_app.sh 2>/dev/null | head -1)")`. After bump, that pattern still resolves correctly.

## Don't

- **Don't break existing exit codes.** The current contracts are referenced from CLAUDE.md files in consuming projects (Konjugieren has explicit exit-5 semantics for `launch_app.sh`'s modal-gating hint). New exit codes are fine; renumbering existing ones is not.
- **Don't rename scripts.** Consumers reference scripts by name (`build_app.sh`, `screenshot.sh`, etc.); renames break every consuming project's CLAUDE.md and shell history.
- **Don't add interactive prompts.** Every script must run unattended for Claude Code automation. New `--flag` defaults must preserve non-interactive behavior.
- **Don't expand scope.** The four changes above are scoped to friction points actually observed. Tempting adjacent improvements (e.g., a `screenshot.sh --replace <slug>` flag for iteration churn, or a config validator) should be surfaced as separate next-iteration prompts rather than bundled here.
- **Don't commit without confirming with Josh** — the skill repo follows the same project rule as Konjugieren (see CLAUDE.md).

## What's next after this batch

Two open questions worth surfacing once these land:

1. **Should `screenshot.sh` accept an explicit `--path`** override for cases where the auto-named slug-timestamp convention doesn't fit? The slug-only contract is currently strict; the friction this session was minor (good error message, self-correcting), but the contract is a recurring source of first-time confusion.

2. **Is there value in a `cleanup_attempts.sh`** that prunes stale screenshots matching a pattern? Once `scroll_to_label.sh` lands (#2), iteration churn drops, but legacy screenshots from past exploratory sessions accumulate. A simple `find docs/screenshots/ -name '*-attempt*.png' -delete`-equivalent helper might earn its keep — or might be too project-specific to ship in the skill.

Both are lower priority than the four above. Surface to Josh after #1–#4 ship.
