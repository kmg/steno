# ADR-0008: Custom linter — `tools/lint-steno.swift`

* **Status:** Accepted — 2026-05-29
* **Decision Makers:** Ganesh
* **Supersedes:** —
* **Last reviewed:** 2026-05-29

## Context and Problem Statement

Several rules in `AGENTS.md` and the ADRs are easy to violate accidentally during AI-paired editing: forgetting `CodingKeys` on a new Codable type, leaving `print()` in a quick debug, dropping `try!` to get past a compiler error, or backsliding into bare `Logger(subsystem:category:)` after [ADR-0007](0007-structured-logging-and-debug-tab.md) established `StenoLog`. SwiftLint defaults don't enforce these specific rules. Saying "Claude, please don't" in `AGENTS.md` works when the rule is fresh; backslides after a few weeks.

What's needed is a custom linter that fails the relevant rules with embedded remediation hints — error messages that tell Claude (or future-Ganesh) the exact fix.

## Decision Drivers

- **The rules already exist** in `AGENTS.md` and the ADR set. The linter just enforces them mechanically. No new policy.
- **Iteration-3 rule** (a  pattern worth importing): if the same class of error has been fixed manually three times, write a tool. `Logger(subsystem:category:)` was fixed 15 times during the ADR-0007 refactor — exactly the case the rule was made for.
- **Error messages should embed remediation hints** so Claude can act on them directly without needing to re-derive the fix.
- **Solo dev: low ceremony is mandatory.** A 200-line Swift script is the right size. SwiftSyntax-based linters are overkill at this scope and need rebuilding when Swift evolves.
- **Hookable.** The linter should be runnable as a Claude Code PreToolUse hook on `*.swift` edits, so violations fire at write time, not later.

## Considered Options

### Option 1: SwiftLint + custom rules

* **Good:** Off-the-shelf, well-known.
* **Bad:** SwiftLint custom rules are regex-based with no embedded remediation. The error messages are terse.
* **Bad:** Adds a dependency. Steno currently has no Ruby/SwiftLint setup.
* **Bad:** Per-rule configuration in `.swiftlint.yml` is its own ceremony.

### Option 2: SwiftSyntax-based linter

* **Good:** Real AST, no false positives.
* **Bad:** SwiftSyntax APIs evolve; we'd be on a treadmill.
* **Bad:** Substantial code to set up. Overkill for ~5 rules.

### Option 3: Single-file Swift script with regex rules

* **Good:** ~200 LOC. No dependencies.
* **Good:** Easy to extend — adding a rule is adding a function.
* **Good:** Error format is fully ours — we can embed multi-line remediation hints.
* **Neutral:** Regex-based, so false positives are possible. Mitigation: keep rules conservative; fail explicit and obvious patterns only.
* **Neutral:** False negatives also possible. Accept — the linter is one defensive layer, not a complete enforcement.

## Decision Outcome

**Selected: Option 3 — single-file Swift script.**

### The script

`tools/lint-steno.swift` is executable Swift (`#!/usr/bin/env swift` shebang). Run as:

```bash
./tools/lint-steno.swift Steno/                              # all of Steno/
./tools/lint-steno.swift Steno/Audio/RecordingPipeline.swift # one file
```

Exit codes: `0` clean, `1` violations, `2` argument error.

### Rules in v1

| Rule | What it catches | Source rule |
|---|---|---|
| `max-file-loc` | File > 500 non-blank, non-comment lines | Generic file-size signal (matches  convention) |
| `no-try-bang` | `try!` outside `*Tests.swift` | AGENTS.md error handling discipline |
| `no-print` | `print(` or `NSLog(` outside `*Tests.swift` | ADR-0007 + AGENTS.md "Logging" |
| `no-bare-logger` | `Logger(subsystem:` outside `Steno/Services/Logging/` | [ADR-0007](0007-structured-logging-and-debug-tab.md) |
| `codable-explicit-coding-keys` | A `struct`/`class` declared Codable but the file has no explicit `CodingKeys` enum | Catches drift between Swift property names and on-disk JSON keys |

### Error format

Each violation prints:

```
<file>:<line>: error: [<rule-id>] <message>
  fix: <remediation hint, multi-line if needed>
```

The remediation hint is full prose, tells Claude exactly what to change. Example for `no-bare-logger`:

> fix: Replace with `StenoLog.<subsystem>` and remove the `import os` if no other os symbols remain. Pick the subsystem that matches the file's responsibility: audio / transcription / diarization / storage / app. Call sites stay the same (`log.info("…")`, `log.error("…")`).

### Hook integration

A Claude Code PreToolUse hook configured at the  level (`.claude/settings.json`) fires the linter on Edit/Write of `create/steno/**/*.swift`. Violations block the operation with the remediation hint visible to Claude. This is the same pattern  uses for its lint-tether.swift.

### Rationale

- Each rule directly traces to an existing policy (AGENTS.md, an ADR, or a documented convention). The linter doesn't introduce new rules; it enforces existing ones.
- The "iteration-3" rule says write a tool after fixing the same thing three times. `no-bare-logger` and `codable-explicit-coding-keys` both crossed that threshold during the ADR-0007 refactor — a linter is the natural codification.
- Embedded remediation hints close the loop: when the linter blocks a write, Claude reads the hint and acts on it without needing to re-derive the rule from AGENTS.md.

### Consequences

**Good:**
- Backsliding on these five rules now produces an immediate failure with a fix attached.
- New ADRs that establish a new rule can register an enforcing lint rule in the same commit — the ADR encodes the *why*, the linter encodes the *how to check*.
- The linter is < 250 LOC and trivial to extend.

**Bad:**
- Regex-based — false positives will happen. Mitigation: rules are conservative; a violation is always fixable in a few lines, even if "wrong."
- Maintenance: the linter itself is code that can rot. Mitigation: it's small enough to read end-to-end during any session that touches it.
- The hook can be locally disabled. The discipline is still partly human.

### Updates downstream

- `tools/lint-steno.swift` — the linter.
- `AGENTS.md` — new "Linter" section pointing at the script and the rule list.
- `.claude/settings.json` ( level) — PreToolUse hook registration for `create/steno/**/*.swift` edits.
- 5 model files gained explicit `CodingKeys` enums (the v1 ruleset surfaced 8 real violations — fixed in the same commit as the linter shipped).

## More Information

- [ADR-0007](0007-structured-logging-and-debug-tab.md) — the rule that `no-bare-logger` enforces.
- 's `tools/lint-tether.swift` — the prior-art template this linter is adapted from.
- Software dark-factory pattern: "custom linters with remediation instructions in error messages" — the operational practice this implements.
