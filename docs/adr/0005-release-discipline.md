# ADR-0005: Release discipline rules

* **Status:** Accepted — 2026-05-29 (retroactive; rules added to `AGENTS.md` 2026-04-21)
* **Decision Makers:** Ganesh
* **Supersedes:** —
* **Last reviewed:** 2026-05-29

## Context and Problem Statement

The v0.2.11–v0.2.14 incident shipped four broken releases in a single session attempting to fix a device-switch crash. A 300-line engine recovery system broke live transcription — the actual fix was two one-liners. Each release failed in a different way; each fix introduced a new bug. The pattern was: see a crash → write code → ship → discover the fix broke something else → repeat.

The root cause wasn't any single bad change. It was the absence of a discipline gate between "I think this fixes it" and "tagged for release." We need explicit rules that prevent this class of failure.

## Decision Drivers

- **Steno's core function is recording and transcribing.** Any release that breaks either is worse than a release that doesn't ship at all.
- **AI pair-programming amplifies both speed and impulsivity.** Without explicit gates, the cycle of "see error → write fix → ship" can iterate four times before lunch.
- **Tag → release is irreversible** (the DMG goes on GitHub Releases, the Homebrew tap points to a specific SHA256). "Pull it back" requires force-pushing tags and rebuilding the Homebrew formula.
- **Device test is the only signal that matters.** Unit tests pass on a v0.2.13 that had broken transcription. Compile success is not validation.

## Considered Options

### Option 1: No explicit rules

Continue with "ship when it seems ready." Trust that the pattern won't repeat.

* **Bad:** The pattern just demonstrated itself across 4 releases. No reason to expect it not to repeat.

### Option 2: Add explicit pre-tag rules to `AGENTS.md`

Codify the lessons as instructions both human and Claude will read at session start.

* **Good:** Lightweight. No new tooling.
* **Good:** AGENTS.md is the natural place — it's the agent-instruction surface.
* **Bad:** Rules can be ignored. Discipline requires enforcement.

### Option 3: Hooks that block tagging

A `.claude/hooks/steno-pre-tag.sh` that fails the tag command unless version matches `project.yml` and a Release build passes.

* **Good:** Enforced, not just suggested.
* **Good:** Catches the obvious mismatch class.
* **Bad:** Only catches mechanical issues. Device-test discipline still has to be human.

## Decision Outcome

**Selected: Option 2 + Option 3 combined.**

Rules codified in `create/steno/AGENTS.md` "Release Discipline" section. Mechanical checks enforced by `.claude/hooks/steno-pre-tag.sh`.

### The five rules

1. **Minimal fix, then stop.** Fix the reported bug. Don't rewrite the subsystem. Don't fix 15 audit issues in one commit. Ship the smallest change that addresses the crash, confirm it works, move on.

2. **Test a full recording before tagging.** Not "it compiles." Not "the unit test passes." Record a real 3-minute meeting, verify transcription flows continuously, then tag. If you can't test on device, don't ship.

3. **Don't bundle unrelated changes.** The streaming transcriber sliding window had nothing to do with the device-switch crash. It was an "improvement" that broke transcription at 90 seconds. One bug, one fix, one release.

4. **Research before implementing, not after shipping.** We shipped the device change handler, then researched how other apps do it. Invert that order.

5. **Protect the core function above all else.** Steno records and transcribes. Every change must be evaluated against: "does this break recording or transcription?" If unsure, don't ship it.

### Rationale

- Each rule is directly traceable to a specific failure in the v0.2.11–v0.2.14 sequence. They aren't generic best practices; they're the postmortem.
- Putting them in `AGENTS.md` means Claude reads them on every session — they're not aspirational, they're operational.
- The `steno-pre-tag.sh` hook catches the mechanical failure modes (version mismatch, Release build broken) so the human gate can focus on the device test.

### Consequences

**Good:**
- v0.2.17 (the first release after these rules landed) was a clean ship. The arch v2 work that drove it had been tested on device weeks before the tag push, and the actual tag-and-ship sequence was deliberate.
- The rules become reusable for steno-ios when that project starts.

**Bad:**
- Rules can drift. A 14-month-old AGENTS.md rule is easier to skip than a 14-day-old one. Mitigation: ADR-0001 commits to updating `Last reviewed:` on changes, which forces re-reading.
- "Minimal fix, then stop" is in tension with refactoring. When a bug fix reveals deeper rot, this rule says ship the minimum first, refactor later. That's correct for individual bugs but can compound technical debt.

### Updates downstream

- `AGENTS.md` "Release Discipline" section — the five rules verbatim.
- `.claude/hooks/steno-pre-tag.sh` — mechanical gate.
- `.claude/commands/steno-release-test.md` — `/steno-release-test` interactive pre-release checklist invokable as a slash command.

## More Information

- `AGENTS.md` "Release Discipline" — the rules as agent-readable instructions.
- The CI test suite work tracked in the backlog adds a second mechanical gate: Release builds must pass CI before tag-push. v0.2.17's build failure (caught by CI only after tag push) demonstrates the gap — see [ADR-0003](0003-macos-15-deployment-target.md) for context on that incident.
