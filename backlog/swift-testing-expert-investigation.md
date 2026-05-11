# Investigation: swift-testing-expert plugin load error

## Context

On this machine, Claude Code's `/reload-plugins` reports one load error, surfaced via `/doctor`:

```
swift-testing-expert@swift-testing-agent-skill [swift-testing-expert]:
  Path escapes plugin directory: ./(skills)
```

This is the harness's plugin-loader path-traversal guard — same family as Python's `tarfile` extraction guard or git's `core.protectHFS`. It refuses to follow a manifest path that resolves outside the plugin's root (via `..`, an absolute path, or an escaping symlink).

## Known facts

- **Plugin source**: `https://github.com/AvdLee/Swift-Testing-Agent-Skill` (marketplace name: `swift-testing-agent-skill`; plugin name: `swift-testing-expert`).
- **Local cache path**: `~/.claude/plugins/cache/swift-testing-agent-skill/swift-testing-expert/1.0.0/`
- **Harness version**: Claude Code `2.1.128` (latest) is currently running. Stable channel is `2.1.119`.
- **Working hypothesis**: harness-version regression. `2.1.128` may have tightened path resolution and now flags a manifest pattern the older harness allowed. The plugin author likely hasn't seen this yet.
- **Blast radius**: bounded. The plugin loaded as a *plugin* (it's counted in the plugins count); only the standalone *skill* registration inside it failed (`/reload-plugins` reported `0 skills` loaded). Agents from the plugin still loaded.
- **Out of scope**: this prompt is hosted in the `ios-build-verify` repo for convenience, but the bug is in a different plugin's cache (`swift-testing-agent-skill`). Do NOT modify any files in `~/Desktop/workspace/ios-build-verify` (the skill loaded cleanly), and do NOT modify other projects on disk. The investigation is read-only for everything except the swift-testing-expert plugin's cache directory itself — and even there, "propose changes," not "make them."

The literal path `./(skills)` in the error reads strangely because the parens are likely the loader's own formatting marking the offending segment. Search for `./skills`, `./skills/...`, or paths with `..`.

## What to do

1. **Read the plugin's manifest files** in `~/.claude/plugins/cache/swift-testing-agent-skill/swift-testing-expert/1.0.0/`:
   - `.claude-plugin/plugin.json`
   - `.claude-plugin/marketplace.json` (if present in the cache; check parent marketplace dir too: `~/.claude/plugins/marketplaces/swift-testing-agent-skill/.claude-plugin/marketplace.json`)
   - Any `SKILL.md` frontmatter in `skills/**/SKILL.md`
   - Anything else in the cache root that smells like a manifest or settings file (look for `*.json`, `*.yaml`, `*.toml`)
2. **Identify the offending path reference**. The error names `./(skills)`, so the suspect manifest pattern is something like a `path: ./skills`, `directory: ./skills`, or a SKILL.md referencing an external file via relative path. Inspect symlinks too: `find ~/.claude/plugins/cache/swift-testing-agent-skill -type l -ls`.
3. **Classify the bug**:
   - **(a) Real path traversal in the plugin's manifest** — a `..` reference, an absolute path, or an escaping symlink.
   - **(b) Harness false-positive on a legitimate pattern** — the harness rejects e.g. `./skills` even though it doesn't escape the plugin root.
   - **(c) Cache-state issue** — a corrupted or stale file in the cache; a `--force` reinstall would fix it.
4. **Propose a fix path** for the verdict:
   - If (a): a plugin-side change. Suggest filing a GitHub issue or PR against `AvdLee/Swift-Testing-Agent-Skill` with the exact line and proposed correction.
   - If (b): a harness-side change. Capture the manifest snippet for an Anthropic feedback report at `https://github.com/anthropics/claude-code/issues`, and suggest a local workaround if applicable.
   - If (c): a one-time cache fix (`/plugin install swift-testing-expert --force` from inside Claude Code, or `rm -rf` the cache dir and reinstall).
5. **Briefly note** whether downgrading the harness (`2.1.128 → 2.1.119`) would dodge the error, in case the user wants to wait out the upstream fix.

## Output

Write a short report (under 400 words) to chat with:

- **Verdict**: (a), (b), or (c), with the offending path and a one-sentence explanation.
- **Proposed fix**: concrete patch (for a), feedback-report bullet points (for b), or local recovery command (for c).
- **Workaround**: what the user can do today to suppress the error without waiting on upstream, if anything.

Investigation only — propose changes, do not make them. The user (Josh) will decide whether to file the upstream report, apply a local fix, or leave it.
