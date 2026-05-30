# ADR-0003: macOS 15.0 deployment target

* **Status:** Accepted — 2026-05-29
* **Decision Makers:** Ganesh
* **Supersedes:** Implicit prior decision: macOS 14.2 (Sonoma) — unrecorded, made at project start because Core Audio Taps requires 14.2
* **Last reviewed:** 2026-05-29

## Context and Problem Statement

Steno originally targeted macOS 14.2 because Core Audio Taps (the system-audio capture API used by `SystemAudioCapture`) was introduced in macOS 14.2 and is the foundational capability the app sells on. v0.2.17 was tagged with the deployment target still at 14.2, but the v0.2.17 release build failed in CI because `AudioConverter` (added in the arch v2 work — see [ADR-0004](0004-audio-architecture-v2.md)) uses `AVAssetExportSession.export(to:as:)` which is macOS 15.0+ only.

Local Xcode build had let the deployment-target mismatch slide; CI Xcode 16.2 strict checking did not. Three Swift availability errors on the same root cause.

The fix needs to either:
1. Bump deployment target to 15.0
2. Replace the macOS 15 async API with the older `exportAsynchronously()` + continuation pattern that works on 14.x
3. Gate `AudioConverter` with `@available(macOS 15.0, *)` and have callers fall back on 14.x (WAV stays as `.wav`, never converted to `.m4a`)

## Decision Drivers

- macOS 15 (Sequoia) launched September 2024 — by 2026-05 it's been out 20+ months. Reasonable adoption assumption.
- Ganesh (sole active user during development) is on macOS 15.
- The arch v2 design specifically chose the macOS 15 async export API for its atomicity guarantees (write to temp file → verify duration > 0 → atomic rename). The older API doesn't compose as cleanly.
- v0.2.14 still works for any macOS 14.x holdouts — they have a stable fallback. They miss arch v2's device-switch crash fixes, but those crashes mostly affected 14.x users on Bluetooth.
- "Don't bundle improvements" (per release discipline — see [ADR-0005](0005-release-discipline.md)) — keep the v0.2.17 release scoped to a single change.

## Considered Options

### Option 1: Bump deployment target to macOS 15.0

* **Good:** One-line change in `project.yml`. Smallest possible fix.
* **Good:** Keeps the chosen arch v2 export API intact.
* **Good:** macOS 14.x users can stay on v0.2.14 (which is still on GitHub Releases) for the device-change-recovery features.
* **Bad:** Drops macOS 14.x support. Anyone on 14.x trying to upgrade gets a Homebrew dependency error or a Gatekeeper rejection.

### Option 2: Replace `export(to:as:)` with `exportAsynchronously()` + continuation

* **Good:** Keeps deployment target at 14.2.
* **Bad:** More code change. The atomic-write pattern needs reimplementation around the older callback-based API.
* **Bad:** Bundles a code change into the deployment fix — exactly what the release discipline rule says not to do.

### Option 3: Gate AudioConverter with @available(macOS 15.0, *)

* **Good:** Keeps deployment target at 14.2.
* **Bad:** macOS 14.x users get .wav files that never convert to .m4a. Confusing UX (large files, weird format).
* **Bad:** All call sites of `AudioConverter.convertToAAC` need `if #available(macOS 15.0, *)` guards. Spreads the constraint through the codebase.

## Decision Outcome

**Selected: Option 1 — bump to macOS 15.0.**

### Rationale

- Single-line change, smallest blast radius.
- The arch v2 design's choice of macOS 15 APIs was deliberate (see [ADR-0004](0004-audio-architecture-v2.md)). Reverting to the older API to preserve 14.x compatibility undoes a design decision that wasn't being questioned.
- macOS 14.x users have a working version (v0.2.14) and can wait until they upgrade.

### Consequences

**Good:**
- v0.2.17 builds cleanly on CI.
- Future code can freely use macOS 15 APIs without availability guards.

**Bad:**
- Loss of macOS 14.x support. Users on older Macs are stuck on v0.2.14 indefinitely.
- Homebrew cask `depends_on macos: ">= :sequoia"` (bumped from `:sonoma`).

### Updates downstream

- `project.yml`: `macOS: "15.0"`
- `README.md`: "Requirements: macOS 15.0+ (Sequoia)"
- `AGENTS.md`: "Native macOS transcription app. Swift/SwiftUI, Apple Silicon, macOS 15.0+."
- Homebrew cask `Casks/steno.rb`: `depends_on macos: ">= :sequoia"`

## More Information

- [ADR-0004](0004-audio-architecture-v2.md) — the architecture decision that required macOS 15 APIs.
- [ADR-0005](0005-release-discipline.md) — the "don't bundle unrelated improvements" rule that drove Option 1 over Option 2.
- Apple docs: `AVAssetExportSession.export(to:as:)` introduced macOS 15.0.
