# ADR-0007: Structured logging subsystems + in-app Debug tab

* **Status:** Accepted — 2026-05-29
* **Decision Makers:** Ganesh
* **Supersedes:** Implicit prior decision: per-file `Logger(subsystem:category:)` with no in-app surface
* **Last reviewed:** 2026-05-29

## Context and Problem Statement

Steno's current logging pattern is `private let logger = Logger(subsystem: "com.kmganesh.steno", category: "<class-name>")` in each file. The events are written to `os_log`, viewable via `Console.app` or `log stream` from the command line. There is no in-app surface for the log stream.

This creates two failure modes that have already cost real time:

1. **Silent failures.** During the v0.2.11–v0.2.14 incident, recording would stop without obvious user-facing signal. Events that explained why (engine config change, format mismatch, buffer underrun) were in `os_log` but invisible to the user-as-debugger. By the time anyone thought to look in `Console.app`, the relevant entries had aged out.
2. **Diagnostics for non-developer users.** When a user reports "recording didn't work," there's no "Share Diagnostics" button. They can't reasonably be asked to open Console.app, filter on `com.kmganesh.steno`, and copy the right lines.

Rich Hickey's caveat applies: every bug found in the field passed the type checker AND all the tests. Operations is the unsolved part. We need behavior-level observability inside the app.

## Decision Drivers

- **The v0.2.11–v0.2.14 incident would have ended on day 1 with a Debug tab.** Engine-died events, buffer-stalled events, format-mismatch events — all already being logged. Just invisible.
- **Solo dev + AI workflow means the user IS the debugger.** Need an in-app surface, not a separate tool.
- **Log volume is high.** Audio thread emits dozens of events per second during recording. A ring buffer per subsystem prevents memory growth.
- **Existing `os_log` integration should stay.** Don't lose the standard Apple diagnostic surface — system tools depend on it.
- **Subsystem partitioning matters more than category-per-file.** All 10 audio-related files belong in one subsystem (`audio`), not 10 separate categories. Lets users filter on the bug-class they're investigating.

## Considered Options

### Option 1: Status quo — `Logger(subsystem:category:)` per file, no in-app surface

* **Bad:** Already demonstrated as insufficient (the v0.2.11–v0.2.14 lesson).

### Option 2: `OSLogStore` polling for in-app surface

Use `OSLogStore` to query `os_log` entries every N seconds and display in a Debug view. No changes to existing logging code.

* **Good:** Zero changes to existing `logger.info(...)` calls. Just a new file + view.
* **Bad:** `OSLogStore` requires elevated entitlements on macOS in some configurations. Permissions are fragile.
* **Bad:** Polling has latency (last-1s vs real-time). Audio thread emits at sub-second cadence.
* **Bad:** Can't easily attach extra structured fields (e.g. session ID) — `OSLogStore` returns formatted strings.

### Option 3: `StenoLog` facade with subsystem statics + in-memory ring buffer

Introduce `StenoLog` as a static facade with one entry per subsystem: `StenoLog.audio.info(...)`, `StenoLog.transcription.error(...)`, etc. Each call:
1. Writes to the underlying `os.Logger` (preserves system tool integration).
2. Appends to an NSLock-protected per-subsystem ring buffer (`LogStore`).

Debug view reads from the ring buffer with periodic refresh.

* **Good:** Real-time updates without polling.
* **Good:** Structured `LogEvent` (timestamp, level, subsystem, message) — easily exportable as JSON.
* **Good:** Preserves `os_log` integration for `Console.app` and `log stream` users.
* **Neutral:** Requires refactoring ~10 existing `Logger(subsystem:category:)` declarations and ~50 call sites. Mechanical but real.
* **Bad:** New global state (the ring buffers). NSLock-protected per thread-safety rules — see [ADR-0006](0006-v0.1.x-retroactive-decisions.md) Decision E.

## Decision Outcome

**Selected: Option 3.**

### Architecture

```
┌────────────────────────────────────────────────────────────┐
│                    StenoLog (facade)                       │
│                                                            │
│  static audio: StenoLogger                                 │
│  static transcription: StenoLogger                         │
│  static diarization: StenoLogger                           │
│  static storage: StenoLogger                               │
│  static app: StenoLogger                                   │
└──────────────┬─────────────────────────────────────────────┘
               │
               ▼
┌────────────────────────────────────────────────────────────┐
│                    StenoLogger                             │
│                                                            │
│  let subsystem: LogSubsystem                               │
│  let osLogger: os.Logger                                   │
│                                                            │
│  info(_:), warning(_:), error(_:), debug(_:)               │
│   ├─ writes to osLogger (preserves Console.app)            │
│   └─ appends LogEvent to LogStore.shared                   │
└──────────────┬─────────────────────────────────────────────┘
               │
               ▼
┌────────────────────────────────────────────────────────────┐
│              LogStore.shared (singleton)                   │
│                                                            │
│  NSLock-protected ring buffer per subsystem                │
│  ~200 events per subsystem (configurable)                  │
│  snapshot() → [LogEvent]                                   │
│  clear()                                                   │
│  exportText(subsystems:, levels:) → String                 │
└────────────────────────────────────────────────────────────┘
```

### Subsystems

| Subsystem | Files |
|---|---|
| `audio` | All `Steno/Audio/*.swift` (10 files) |
| `transcription` | `TranscriptionEngine`, `StreamingTranscriber` |
| `diarization` | `DiarizationManager`, `MLDiarizer` |
| `storage` | `SessionStore`, `CrashRecovery` |
| `app` | `StenoApp`, `UpdateChecker`, `Analytics` |

Five subsystems is enough to partition the bug-classes; not so many that filtering becomes ceremony.

### Debug surface

`SettingsView` is restructured into a `TabView` with two tabs: **General** (existing content) and **Debug** (new). The Debug tab shows:

- Per-subsystem event count + last-event time at the top.
- A filterable list of `LogEvent`s, newest first, color-coded by level.
- Filter chips for subsystem (multi-select) and level (info/warning/error).
- "Share Diagnostics" button — copies a plain-text export of the current filter view to clipboard, or opens `NSSharingServicePicker` for direct share.
- "Clear" button to reset all ring buffers.

The list polls the store every 1 second when the Debug tab is foreground. Polling-while-foreground avoids fighting with audio-thread emission rate.

### Thread safety

- `LogStore` is NSLock-protected (consistent with [ADR-0006](0006-v0.1.x-retroactive-decisions.md) Decision E for audio-thread-safe state).
- `LogStore.snapshot()` returns a value-type copy under the lock — UI never holds the lock.
- `StenoLogger` writes are sync — no async hops on the audio thread.

### Rationale

- The refactor is mechanical: each `private let logger = Logger(subsystem:category:)` becomes `private let log = StenoLog.<subsystem>`. Call sites `logger.info(...)` become `log.info(...)`. ~50 mechanical edits.
- The in-app surface directly addresses the Hickey caveat — users (or future-Ganesh) can debug behavior without reading code.
- Sharing diagnostics from inside the app means crash/issue reports can include actual log evidence, not vague "it didn't work" descriptions.

### Consequences

**Good:**
- A user reporting "recording stopped" can open Settings → Debug, see the `audio: engine config change` event, and share it.
- Future bugs in the same class as v0.2.11–v0.2.14 are visible in real time.
- The `LogEvent` shape is structured enough to JSON-export for crash-report integration with Sentry later.
- Subsystem partitioning is a step toward steno-ios's structured logging discipline (same pattern, transplanted greenfield).

**Bad:**
- ~250 LOC of new code (StenoLog + LogStore + DebugTabView + tests).
- ~50 mechanical edits at call sites.
- Memory cost: 5 subsystems × ~200 events × ~200 bytes each = ~200KB. Acceptable.
- SettingsView restructure from `Form` to `TabView` + nested General tab. Cosmetic, but user-visible.

## Updates downstream

- `Steno/Services/Logging/StenoLog.swift` — new file (facade + LogStore + types).
- `Steno/Views/Settings/DebugTabView.swift` — new file (Debug tab content).
- `Steno/Views/SettingsView.swift` — wrapped in TabView; existing content moved to a `GeneralSettingsTab` view.
- 10 source files refactored from `Logger(subsystem:category:)` to `StenoLog.<subsystem>`.
- `StenoTests/StenoLogTests.swift` — new tests covering ring buffer behavior, capacity eviction, thread safety.
- `ARCHITECTURE.md` — note StenoLog as the canonical logging surface.
- `AGENTS.md` — add a "Logging" section reflecting the new convention.

## More Information

- [ADR-0006](0006-v0.1.x-retroactive-decisions.md) Decision E — the NSLock-over-actors rule that LogStore inherits.
- Hickey, *Simple Made Easy* — the operations-is-unsolved frame this ADR addresses.
- Apple's `os_log` and `OSLogStore` docs — for context on what the system surface provides.
