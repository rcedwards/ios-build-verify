# Implementation prompt: identifier-rollup heuristic for `FIRST_SCREEN_ID` at setup time

## Context

You are working in `~/Desktop/workspace/ios-build-verify` — the source repo for the `ios-build-verify` Claude Code skill. The skill is published at `https://github.com/vermont42/ios-build-verify`.

This prompt is the surviving change from a May 2026 Konjugieren-validation next-iteration batch. The other two changes in that batch — `describe_ui.sh --point` and `tap_xy.sh --verify-target` — shipped at commit `0ee193e`. This one was tagged LOWER priority and not landed; it's preserved here for future-you.

## Design principle to apply

**SKILL.md line 35: "Mechanize prose recipes."** SKILL.md's "Identifier rollup" section already documents the failure mode and the two recovery patterns (move the identifier to a leaf; wrap the parent in `.accessibilityElement(children: .contain)`). The user-facing semantics don't need to change. The opportunity is to detect the foot-gun at setup time — before the user wires up their app, runs `launch_app.sh`, and burns an iteration on a verify-op exit-4 they didn't expect — instead of leaving them to discover it through failure.

## Change to make

### Identifier-rollup heuristic for `FIRST_SCREEN_ID` at setup time

**Why.** `setup_project.sh`'s post-write source check (via `find_id_in_source.sh`) confirms `FIRST_SCREEN_ID` exists in Swift but doesn't check whether the identifier is on a leaf element. SwiftUI rolls a parent's `.accessibilityIdentifier` over every descendant in the AXTree (see SKILL.md "Identifier rollup"), so an identifier on a `VStack`/`ZStack`/`HStack`/`Form`/`NavigationStack` defeats verification — the launch anchor will be present in the tree under the correct ID, but every other element in the screen will share that ID, breaking other verify ops.

**Implementation outline.**

After the existing `find_id_in_source.sh` check in `setup_project.sh` (around line 270), inspect a small window of context above each match:

```bash
# Heuristic: if the line containing .accessibilityIdentifier(...) follows a
# } closing brace and the brace's matching opening container is one of the
# rollup-prone parents, warn.
```

Or simpler: walk back from the match line for ≤10 lines, count `{` vs `}`, and check whether the most recent unmatched `{` follows a `VStack`/`ZStack`/`HStack`/`Form`/`NavigationStack`/`LazyVStack`/`LazyVGrid` opening.

**False positives are acceptable** — the warning should be advisory, not blocking. Same shape as the existing source-check warning ("not found in Swift source; proceeding anyway"). Suggest the user move the identifier to a leaf or wrap the parent in `.accessibilityElement(children: .contain)` per the SKILL.md recovery patterns.

**Hooks into `audit_view.sh`** if that script already has rollup-detection logic — reuse rather than duplicate.

**CLAUDE.md updates.** None — the heuristic improves setup-time validation but doesn't change the user-facing rollup semantics already covered in the "SwiftUI identifier rollup" bullet.

## Testing approach

Unit-test against fixture Swift files containing both safe (leaf-element identifier) and unsafe (parent-container identifier) patterns. Either temporary fixtures in a `tests/` directory or inline in a test script under `scripts/`.

Re-run `setup_project.sh` against a clean tmp dir to confirm the new behavior doesn't regress the existing setup colloquy. The `/tmp/ibv-test` pattern from the earlier validation works:

```bash
cd /tmp && rm -rf ibv-test && mkdir ibv-test && cd ibv-test && touch Foo.xcodeproj
~/Desktop/workspace/ios-build-verify/skills/ios-build-verify/scripts/setup_project.sh \
  --app-name Foo --bundle-id com.example.Foo --scheme Foo --target-sim "iPhone 17" \
  --first-screen-id foo_anchor --main-tabs "a b c"
```

Run `bash -n` on every edited script before committing.

## Useful files to read first

- `skills/ios-build-verify/SKILL.md` "Identifier rollup" section — semantics and recovery patterns the warning should cite.
- `skills/ios-build-verify/scripts/setup_project.sh` — lines around the `find_id_in_source.sh` invocation are where this change lands.
- `skills/ios-build-verify/scripts/find_id_in_source.sh` — current source-check behavior; the warning shape this change should match.
- `skills/ios-build-verify/scripts/audit_view.sh` — may already have rollup-detection logic worth reusing.
