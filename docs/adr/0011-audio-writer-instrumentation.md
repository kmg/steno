# ADR-0011: Audio writer instrumentation — frames-written, drop counter, heartbeat

* **Status:** Accepted — 2026-05-30
* **Decision Makers:** Ganesh
* **Supersedes:** —
* **Last reviewed:** 2026-05-30

## Context and Problem Statement

A recording session on 2026-05-30 at 09:06 produced an `audio.wav` file containing **only the RIFF header (4 KB) — zero audio frames**. The user pressed record, the UI showed an active recording for ~8 minutes, the user pressed stop, and the only log signal that surfaced was "AAC conversion failed" — a downstream error from `AudioConverter` complaining that the empty WAV couldn't be turned into an m4a. The actual root cause (all incoming buffers being silently dropped at `AudioFileWriter.append`'s format-validation gate) emitted exactly one log line: `"Buffer sample rate ... != file sample rate ..., dropping buffer"` — gated by a `_formatMismatchLogged` boolean that fires once per writer lifetime.

The Hickey caveat applies directly: the type checker and existing tests pass on this code. The bug is in *operations* — the writer is doing what it was told to do (reject buffers it can't accept) but doing it so quietly that the user can't tell anything is wrong.

The Debug tab (ADR-0007) is the right surface for these signals. But the signals themselves have to exist.

## Decision Drivers

- **The 09:06 incident is the immediate motivation.** A user-affecting failure that left no visible trail until 8 minutes after it happened.
- **Audio thread is real-time.** Logging on every buffer is unacceptable (~50 emissions per second per source). Anything we add has to be throttled or batched.
- **The Debug tab can now show event streams in real time.** It exists; it just needs the events to be richer.
- **Test coverage exists at the unit level for `AudioConverter`.** Extend the pay-as-you-go pattern to `AudioFileWriter`.
- **Failure mode is the same shape as ADR-0007's motivation.** Silent operation that hides until downstream. The fix is the same shape: surface the events.

## Considered Options

### Option 1: Status quo — single "buffer dropped" log per writer lifetime

* **Bad:** Already demonstrated. One log line for 8 minutes of all-buffers-dropped is identical to zero log lines for someone reading the trace.

### Option 2: Log every buffer drop

* **Bad:** Audio-thread emission rate. ~50/sec from a single mic. Floods unified logging and the Debug tab ring buffer. Drowns useful signals.

### Option 3: Throttled drop counter + periodic heartbeat + finish-time report

Add to `AudioFileWriter`:

- `framesWritten: AVAudioFramePosition` — incremented on each successful append
- `buffersDropped: Int` — incremented on each dropped append
- `lastDropLogAt: Date?` — throttle drop warnings to once per N seconds
- `lastHeartbeatFrames: AVAudioFramePosition` — emit info-level heartbeat every ~10s of audio
- `finish()` logs final totals; **emits an `.error`-level event if `framesWritten == 0`** so the empty-WAV case is unmistakable

* **Good:** Audio-thread overhead is constant (a few integer adds + an occasional `Date()` comparison).
* **Good:** Steady-state recording produces ~6 events/minute (heartbeats) in the Debug tab — enough to see "progress is happening" without noise.
* **Good:** Failure mode (all-drop) produces one warning every 5s plus growing drop counter, then an unmistakable error at finish: `"Audio writer finished with 0 frames written (N buffers dropped) — recording appears empty"`.
* **Good:** Counters are exposed via a `counters` snapshot property — the Debug tab can read them directly without going through the log stream.

## Decision Outcome

**Selected: Option 3.**

### Implementation summary

- Counters reset in `start(outputURL:sourceFormat:)` so each session starts at zero.
- `append(buffer:)` increments `framesWritten` on success, `buffersDropped` on format mismatch.
- Drop log throttled to once every 5s (`dropLogThrottleSeconds`).
- Heartbeat fires every `heartbeatFrameInterval` (480,000 frames ≈ 10s at 48kHz, ≈ 30s at 16kHz — Bluetooth/HFP sample rate). Real-world cadence is "roughly every 10 seconds of audio."
- `finish()` reads the final counters before tearing down state, then emits one of two log lines:
  - **0 frames** → `error`: "Audio writer finished with 0 frames written (N buffers dropped) — recording appears empty"
  - **>0 frames** → `info`: "Audio writer finished: Xs (N frames), M drops"
- New `counters` property returns `(framesWritten, buffersDropped)` under the lock — for tests and future Debug-tab counter display.

### Test coverage

`StenoTests/AudioFileWriterTests.swift` — 7 tests:

- `test_start_setsIsWriting` — sanity
- `test_appendMatchingBuffer_incrementsFrameCount` — counters track writes
- `test_appendMismatchedBuffer_incrementsDropCount` — counters track drops
- `test_allBuffersDropped_morningIncidentScenario` — the 09:06 case, asserts 100 drops + 0 writes
- `test_finish_resetsState` — `isWriting` flips back to false
- `test_startAfterFinish_resetsCounters` — second session starts fresh
- `test_appendWithoutStart_isNoop` — calling append before start does nothing

All 7 pass in ~1.4s locally.

### Generalization

This pattern (counter + throttled warning + periodic heartbeat + finish-time report) is the right shape for any service-layer component that silently drops or filters inputs. Specifically transferable:

- `SystemAudioCapture` — has its own buffer flow; same silent-drop risk
- `StreamingTranscriber` — accepts buffers, processes asynchronously; could drop on backpressure
- `AudioConverter` — already logs once on failure, could surface a more granular "input had N frames" message

When implementing the next such component, follow this pattern by default rather than starting with a single boolean flag.

### Consequences

**Good:**
- The 09:06-class failure (writer running, no frames flowing) produces unmistakable signal in real time.
- Steady-state recordings show "Writer heartbeat: 30.0s, 1440000 frames, 0 drops" every ~10s — useful confirmation that the pipeline is healthy.
- The pattern is now established; future Service components can copy it.

**Bad:**
- Per-call overhead increases (a few integer additions + occasional `Date()` for drop throttle). Negligible at audio-thread cadence.
- Heartbeat cadence is frame-based, not time-based, so a recording at 8kHz heartbeats every minute instead of every 10s. Acceptable — Bluetooth/HFP at 16kHz is the lowest realistic rate (~30s cadence).
- The "appears empty" error wording is human-readable but somewhat informal for a structured log. Acceptable given the audience is "user reading the Debug tab" rather than a log-parsing pipeline.

## Updates downstream

- `Steno/Audio/AudioFileWriter.swift` — counters + heartbeat + finish report
- `StenoTests/AudioFileWriterTests.swift` — 7 tests
- `ARCHITECTURE.md` — note the instrumentation in the AudioFileWriter file reference

## More Information

- [ADR-0007](0007-structured-logging-and-debug-tab.md) — the structured-logging system this ADR emits into.
- [ADR-0006](0006-v0.1.x-retroactive-decisions.md) Decision E — NSLock-over-actors for audio-thread code, which the instrumented counters inherit.
- Rich Hickey, *Simple Made Easy* — "every bug found in the field passed the type checker and all the tests"; operations is unsolved; behavior-level observability is the substitute.
