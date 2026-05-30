# ADR-0002: ADR format — MADR

* **Status:** Accepted — 2026-05-29
* **Decision Makers:** Ganesh
* **Supersedes:** —
* **Last reviewed:** 2026-05-29

## Context and Problem Statement

[ADR-0001](0001-record-architecture-decisions.md) committed to keeping ADRs. This ADR locks in the format. The decision matters because format friction directly affects whether ADRs actually get written.

## Decision Drivers

- Solo + AI workflow: both Ganesh and Claude should be able to write and read ADRs without ceremony.
- Markdown-native — lives next to code, renders in GitHub and locally.
- Lightweight: the format should add ~5 minutes of structure, not 30 minutes of template-filling.
- Discoverable: structure should make the *decision*, *alternatives*, and *consequences* easy to find at a glance.

## Considered Options

### Option 1: Nygard's original — Context / Decision / Consequences

* **Good:** Simplest possible structure.
* **Good:** Universally understood.
* **Bad:** No explicit slot for *considered options* — they get folded into Context or Decision, which makes them harder to find.
* **Bad:** No status lifecycle.

### Option 2: MADR — Markdown Architecture Decision Records ([adr/madr](https://github.com/adr/madr))

* **Good:** Explicit *Considered Options* with Pros/Cons. Aligns with how AI agents reason ("here are the alternatives I evaluated").
* **Good:** Status lifecycle (Proposed / Accepted / Rejected / Deprecated / Superseded by).
* **Good:** Actively maintained, large adoption.
* **Good:** Markdown-native, no tooling needed.
* **Neutral:** Slightly more sections than Nygard but each is short.

### Option 3: Y-Statement (one-sentence style)
* **Good:** Compact.
* **Bad:** Too compact to capture rejected alternatives — exactly the thing we most want to preserve.

### Option 4: Multiple formats coexisting
* **Bad:** Cited in [AWS guidance](https://aws.amazon.com/blogs/architecture/master-architecture-decision-records-adrs-best-practices-for-effective-decision-making/): teams that adopt both Nygard and Y-Statement in the same week will pick one and forget the other within a quarter.

## Decision Outcome

**Selected: MADR.**

### Rationale

- The "Considered Options" section is the single most valuable part of an ADR for an AI agent reading it months later — it shows which alternatives were already evaluated and why they lost.
- Status lifecycle catches deprecated ADRs without deleting them — important because deleted decisions tend to get re-litigated.

### Conventions for this project

- File naming: `NNNN-kebab-case-decision-title.md` (per ADR-0001's sequential-numbering rule).
- Top metadata: Status, Date, Decision Makers, Consulted (optional), Supersedes (optional), Last reviewed.
- Mutable per AWS guidance: insert new context with date stamps rather than rewriting. Bump *Last reviewed* on every change.
- Superseded ADRs stay in the repo with `Status: Superseded by ADR-NNNN`. They are not deleted.
- Cross-link ADRs liberally — `(see ADR-0005)` is cheap and helps the next reader navigate.

### Consequences

**Good:**
- A consistent, low-friction template that both Ganesh and Claude can produce quickly.
- Rejected alternatives are preserved in a discoverable slot.

**Bad:**
- ADRs that don't really have alternatives ("Use UTF-8") feel awkwardly templated. Acceptable cost — the template loosens to fit when needed.

## More Information

- [MADR project](https://github.com/adr/madr) — templates and examples.
- [AWS Architecture Blog on ADR best practices](https://aws.amazon.com/blogs/architecture/master-architecture-decision-records-adrs-best-practices-for-effective-decision-making/) — sources for the mutability + don't-introduce-multiple-formats guidance.
