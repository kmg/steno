# ADR-0010: CI test workflow on every push

* **Status:** Accepted — 2026-05-29
* **Decision Makers:** Ganesh
* **Supersedes:** —
* **Last reviewed:** 2026-05-29

## Context and Problem Statement

Until now, GitHub Actions only ran on tag pushes (`.github/workflows/release.yml`). The implication: a Release build only happens at the moment of "I want to ship this." If the Release config has a problem — a Swift availability error, a missing entitlement, a broken dependency resolution — it's discovered *after* the tag is pushed, when the workflow fails post-tag.

This directly cost a release cycle on 2026-05-29:
- `v0.2.17` tag pushed at SHA `9fbfeda`
- Build #40 failed in 3m 28s on Swift availability errors (`AudioConverter.convertToAAC` uses macOS 15+ `AVAssetExportSession.export(to:as:)`, deployment target was 14.2)
- Required: tag delete + push fix commit + retag + wait for Build #41 + verify
- Net cost: ~30 min of extra cycle for an error that would have been caught by any push-time CI

A CI test workflow that runs on every push to main (and PR) closes this gap. The lint + Debug build + test sequence catches the same class of error before it reaches a release tag.

## Decision Drivers

- **The v0.2.17 incident is the immediate motivation.** It's exactly the kind of failure CI is for: a structural error caught by `xcodebuild` strictness, invisible in a local build that used a newer Xcode.
- **Tests already exist.** `StenoTests/LogStoreTests.swift` has 11 tests from [ADR-0007](0007-structured-logging-and-debug-tab.md). Running them in CI is free signal.
- **The linter exists too.** [ADR-0008](0008-custom-linter.md) added `tools/lint-steno.swift`. Running it in CI catches the rules mechanically, including the `no-inline-sdk-key` and `no-private-parent-ref` defenses that should not depend on every commit author remembering to run the linter locally.
- **Solo dev: discipline gates that can be skipped will be skipped sometimes.** Pre-commit hooks are human-skippable; CI is not.

## Considered Options

### Option 1: No push-time CI (status quo)

* **Bad:** v0.2.17 demonstrated the failure mode.

### Option 2: Run a full Release build on every push

* **Good:** Matches what `release.yml` already does for tag pushes.
* **Bad:** Slow (5+ min per push) and burns macOS minutes. Notarization signing setup is unnecessary for non-release pushes.

### Option 3: Run Debug build + tests + linter on every push, Release stays tag-only

* **Good:** Fast (~3-4 min). No signing complexity.
* **Good:** Catches Swift compile errors, availability issues, test regressions, lint violations.
* **Good:** Release workflow stays focused on signing + notarization + release publishing.
* **Neutral:** Debug build doesn't exercise the same `SWIFT_OPTIMIZATION_LEVEL` as Release. Some Release-only warnings might still slip through. Acceptable — the 80/20 of structural failures is at the compile/availability layer, which Debug catches.

## Decision Outcome

**Selected: Option 3 — Debug build + tests + lint on every push.**

### Workflow shape (`.github/workflows/test.yml`)

```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  test:
    runs-on: macos-15
    timeout-minutes: 20
    steps:
      - checkout
      - select Xcode 16.2
      - install xcodegen
      - stub Steno.xcconfig with empty values
      - xcodegen generate
      - resolve packages
      - lint        # ./tools/lint-steno.swift Steno/ StenoTests/ docs/
      - build       # xcodebuild Debug, CODE_SIGNING_ALLOWED=NO
      - test        # xcodebuild test
```

### Step ordering rationale

1. **Lint runs first.** Cheapest check. Catches structural issues (inline keys, banned `Logger(subsystem:)`, missing `CodingKeys`) before the expensive build step.
2. **Build runs second.** Catches compile errors and the entire availability-annotation class (the v0.2.17 failure mode).
3. **Test runs last.** Runs only if build succeeded; depends on the built target.

### xcconfig stubbing in tests

Tests run with an empty `Steno.xcconfig` written at the start of the job:

```yaml
- name: Stub Steno.xcconfig
  run: |
    echo "POSTHOG_API_KEY =" > Steno.xcconfig
    echo "SENTRY_DSN =" >> Steno.xcconfig
```

The `project.yml` `configFiles:` directive requires the file to exist. Empty values are fine — `Analytics.swift` no-ops when the keys come back empty from `Bundle.main.infoDictionary` (see [ADR-0009](0009-build-time-config-for-sdk-keys.md)).

### Production builds (release.yml)

The release workflow now writes `Steno.xcconfig` from GitHub Actions secrets (`POSTHOG_API_KEY`, `SENTRY_DSN`) before generating the Xcode project. If a secret is missing, the corresponding value is empty and the SDK init no-ops in the shipped binary — degraded gracefully, not broken.

**Setup required (one-time):** Add `POSTHOG_API_KEY` and `SENTRY_DSN` as repository secrets in GitHub Settings → Secrets and variables → Actions. The values are the same public-by-design vendor keys that live in `Steno.xcconfig` locally.

### Rationale

- The CI feedback loop is the most direct intervention against the class of failure that cost a tag cycle. Run the gates that exist (lint + tests + build) on every push.
- Debug-config build is the right trade-off — fast, catches 80% of structural failures, doesn't require signing infrastructure.
- Stubbed xcconfig keeps tests deterministic. Real keys would risk accidentally sending test events to production analytics.

### Consequences

**Good:**
- Push-time failures fail in <5 min instead of failing post-tag with a 30-min recovery cycle.
- PRs get a green/red signal automatically. If/when the project gets external contributors, this becomes baseline.
- Linter violations (including the no-inline-sdk-key and no-private-parent-ref rules) get caught in CI regardless of whether someone ran the linter locally.

**Bad:**
- Each push consumes ~3-4 min of macOS CI minutes. The free tier provides 2000 min/month for public repos; well within budget at current commit cadence.
- Debug != Release. Release-only warnings (whole-module optimization, `-Os`) won't be caught until tag push. Acceptable risk — the v0.2.17 class of failure is at the language level, not the optimization level.
- The release workflow now requires GitHub secrets to be configured. Without them, production builds ship without SDK keys (graceful degradation, but operationally users lose telemetry).

### Updates downstream

- `.github/workflows/test.yml` — new file, push-time CI.
- `.github/workflows/release.yml` — adds "Write Steno.xcconfig" step that reads from `secrets.POSTHOG_API_KEY` and `secrets.SENTRY_DSN`.
- `AGENTS.md` — note about the required GitHub Actions secrets (one-time setup).
- `tools/lint-steno.swift` — invoked from CI as `./tools/lint-steno.swift Steno/ StenoTests/ docs/`.

## More Information

- [ADR-0005](0005-release-discipline.md) — the v0.2.11–v0.2.14 release incident; the "test on device, then ship" rule remains. CI tests + lint are not a substitute for device test, they're an additional gate.
- [ADR-0009](0009-build-time-config-for-sdk-keys.md) — the xcconfig pattern that test.yml stubs and release.yml fills from secrets.
- The v0.2.17 build #40 failure (Swift availability errors in `AudioConverter`) — the proximate cause for this ADR.
