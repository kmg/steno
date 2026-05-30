# ADR-0001: Record architecture decisions

* **Status:** Accepted — 2026-05-29
* **Decision Makers:** Ganesh
* **Supersedes:** —
* **Last reviewed:** 2026-05-29

## Context and Problem Statement

Steno has been built across many sessions, often with AI pair-programming. The first ~4 weeks of work produced a working app shipped to v0.2.14 with no ADRs — decisions were captured in commit messages, AGENTS.md rules, and a few markdown files scattered across the project. Returning to the project after the 5-week dormancy that followed the v0.2.11–v0.2.14 incident showed the cost: time spent reconstructing *why* WhisperKit, why FluidAudio, why arch v2, why the deployment target was 14.2 (now 15.0). Each of those decisions was made deliberately at the time; none of the *why* survived in a discoverable form.

We need a way to capture decisions in a form that survives sessions, that's discoverable from inside the repo, and that future-self (or future-Claude) can read in a few minutes to reconstruct the reasoning.

## Decision Drivers

- Decisions get lost in chat history within days; commit messages capture the *what* but rarely the *why* and never the rejected alternatives.
- AI pair-programming makes the durable-artifact problem worse: context windows reset; specs and ADRs become the only thing that survives across sessions.
- A solo project has no team to align — but future-Ganesh is effectively a new contributor every time he returns after weeks away. Same problem, different shape.
- Lightweight is better than nothing; nothing is better than a heavy template that gets skipped.
- The v0.2.11–v0.2.14 incident showed what happens when decisions aren't durably recorded: four broken releases in one session because the underlying architectural decision (single mixed audio stream) wasn't visible as a constraint when patching individual crashes.

## Considered Options

1. **No ADRs.** Capture rationale in commit messages + AGENTS.md.
2. **ADRs in `docs/adr/`**, numbered sequentially, lightweight format (MADR).
3. **ADRs in a wiki or external system** (Notion, GitHub Wiki, etc.).

## Decision Outcome

**Selected: Option 2 — ADRs in `docs/adr/`, MADR format, numbered sequentially.**

Format choice is recorded separately in [ADR-0002](0002-madr-format.md).

### Rationale

- In-repo means the decision context lives next to the code it constrains. `grep` works. Claude Code reads it for free.
- Numbered sequentially means we can refer to "ADR-0004" unambiguously in commit messages and in other ADRs.
- MADR is light enough that writing one is a 10-minute exercise; lightweight is the only format that gets used.
- External systems decouple the ADR from the code — exactly the failure mode we're avoiding.

### Consequences

**Good:**
- Future sessions read `docs/adr/` and reconstruct the project's architectural reasoning in ~30 minutes.
- Rejected alternatives are preserved with their rejection rationale, so we don't relitigate them.
- The act of writing an ADR forces the decision to be articulated, which catches half-thought-through choices.

**Bad:**
- A small upfront cost (~10 minutes per ADR).
- Risk of staleness if ADRs aren't kept current. Mitigation: ADRs are mutable per AWS guidance — insert new context with date stamps rather than rewriting; mark superseded ADRs explicitly.
- Retroactive ADRs for past decisions (0003 onward in this initial batch) are necessarily less rich than ADRs written at the time of decision. Future ADRs should be written at decision time, not after.

## More Information

- [ADR-0002](0002-madr-format.md) — format choice (MADR over Nygard).
- [joelparkerhenderson/architecture-decision-record](https://github.com/joelparkerhenderson/architecture-decision-record) — canonical ADR resource.
- [adr/madr](https://github.com/adr/madr) — the MADR template repository.
