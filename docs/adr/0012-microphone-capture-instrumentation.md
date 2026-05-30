# ADR-0012: MicrophoneCapture instrumentation — silent-tap detector at the source

* **Status:** Accepted — 2026-05-30
* **Decision Makers:** Ganesh
* **Supersedes:** —
* **Last reviewed:** 2026-05-30

## Context and Problem Statement

[ADR-0011](0011-audio-writer-instrumentation.md) instrumented `AudioFileWriter` to surface silent-drop failure modes: when buffers reach the writer but get dropped at the format-validation gate, the new counters and finish-time report make the failure visible. v0.2.19 shipped that.

A device-switch test on v0.2.19 (Bose QC headphones connected → disconnected → reconnected mid-recording) ran cleanly: 3 segments, 0 drops, heartbeat firing every 10s, clean concatenation to a 54s AAC. **But the drop counter stayed at zero throughout.** If the writer's drop counter is the only silent-failure detector and a real-world bug doesn't produce drops, the instrumentation doesn't fire.

Re-examining the 2026-05-30 09:06 incident with this in mind: the writer's `buffersDropped` counter was zero too (in fact the counter didn't exist then, but the equivalent log line would only have fired once if every buffer was a format mismatch). The 4096-byte empty WAV at 09:06 is consistent with **the tap callback never firing at all** — not with buffers arriving and being dropped. Different failure mode, different layer.

We need instrumentation at the **source** — `MicrophoneCapture` — that can distinguish:

- "Tap is firing, buffers flowing" (steady-state, happy path)
- "Tap is firing, writer dropping" (caught by ADR-0011)
- "Tap is silent — never fired or stopped firing" (new gap, ADR-0012)

## Decision Drivers

- **The morning-09:06 case still isn't caught after ADR-0011.** Best-guess failure mode is upstream of the writer.
- **The detector has to fire in real time, not at-stop.** An 8-minute empty recording is bad enough; learning at minute 8 that the previous 8 were silent is worse than learning at minute 0:10. Real-time warning gives the user a chance to stop+restart.
- **Audio thread cost matters.** Counter increments are fine; complex logic in the tap callback is not.
- **The silent-tap detector can run on the main run loop.** It only needs to read the counter periodically; doesn't have to be on the audio thread.

## Considered Options

### Option 1: Status quo after ADR-0011 — writer-only instrumentation

* **Bad:** Caught all-buffers-dropped but not no-buffers-arrive (the actual 09:06 failure mode).

### Option 2: Counter + at-stop report only

Track `buffersReceived` in `MicrophoneCapture`. On `stop()`, log "X buffers received." If X is small, the user-as-debugger sees it post-hoc.

* **Good:** Trivial overhead. Composes with the existing writer instrumentation.
* **Bad:** Same flaw as the writer's original single-flag drop logger — the failure is visible only after the recording ends. The user spent 8 minutes recording silence with no real-time signal.

### Option 3: Counter + main-loop timer that warns when the tap is silent for >N seconds

Add to `MicrophoneCapture`:

- `buffersReceived: Int` — incremented in the tap closure (audio thread, NSLock-protected)
- `lastBufferAt: Date?` — set in the tap closure
- `captureStartedAt: Date?` — set on successful `start()`
- A repeating `Timer` (5s interval) that, while `isCapturing`, reads the counter and emits `warning`-level log when the gap from "last buffer" (or `captureStartedAt` if no buffers yet) exceeds 10s

* **Good:** Real-time signal. A user who's about to record an 8-minute empty session sees "Silent mic tap: zero buffers received since start (12.3s ago). Recording will be empty." at the 12-second mark and can stop+restart.
* **Good:** Audio-thread overhead is two writes under a lock; the polling logic runs on main.
* **Good:** Composes with the writer instrumentation — together they cover both "buffers arrive but get rejected" and "buffers never arrive."
* **Neutral:** Timer is `Timer.scheduledTimer` on the main run loop, scheduled in `start()` and invalidated in `stop()`. Standard SwiftUI/AppKit pattern.

## Decision Outcome

**Selected: Option 3.**

### Architecture summary

```
Audio IO thread (tap callback):
  installTap { buffer, time in
    self?.recordTapInvocation()  // ← NEW: lock+increment+timestamp
    bufferHandler(buffer, time)
  }

Main run loop (Timer every 5s):
  checkSilentTap()
    ├── read counter under lock
    ├── compute gap = now - (lastBufferAt ?? captureStartedAt)
    └── if gap > 10s: log.warning("Silent mic tap: ...")
```

### Detector states

| State | gap | count | Log emitted |
|---|---|---|---|
| Healthy | <10s | any | none |
| Never fired | >10s | 0 | `warning`: "zero buffers received since start (Xs ago)" |
| Stalled | >10s | >0 | `warning`: "no buffers in Xs (N received total). Tap may have stalled" |
| Stopped | n/a | final | `info`: "Microphone capture stopped: N buffers received" |

### Throttling

Unlike the writer's drop log (which can fire every buffer), the silent-tap detector fires from a 5s polling timer. No throttling needed — the timer itself is the rate limit. The user sees a warning at most every 5s while the tap is silent.

### Implementation details

- `silentTapTimer: Timer?` — strong reference; invalidated on `stop()` and re-scheduled on `start()`
- `restart()` calls `stop()` then `startWithHandler()`, which restarts the timer correctly; the 2-second debounce gap between is acceptable silence (we expect no buffers during a device transition)
- `counterLock: NSLock` — separate from the existing `restartQueue`; the queue serializes restart callbacks, the lock guards the counter for cross-thread reads

### Rationale

- A silent tap is the only failure mode left at the source layer after the writer instrumentation. Closing it gives full source-to-sink coverage.
- Real-time signal is qualitatively different from at-stop signal for a user who hasn't yet committed to a full recording session.
- The pattern (counter + main-loop polling timer with grace threshold) is reusable. Recommend the same shape for `SystemAudioCapture` next.

### Consequences

**Good:**
- The 09:06-class failure now surfaces within ~12s of recording start instead of at-stop or via downstream AAC failure.
- The two instrumentations together give a clean signal map: source counter (this ADR) + writer counter (ADR-0011). One says "did buffers arrive," the other says "did they get written."
- Steady-state recordings get a single "Microphone capture stopped: N buffers received" at finish — composable with the writer's per-segment report.

**Bad:**
- One more main-loop Timer to manage. Already a few in the app; one more is incremental.
- `[weak self]` capture in the tap closure increases tap callback overhead by one nil-check. Negligible.
- `Timer.scheduledTimer` requires a run loop. `start()` is called from the main thread per ADR-0006 Decision E + the existing convention; this is safe but worth noting if `start()` ever moves.

## Updates downstream

- `Steno/Audio/MicrophoneCapture.swift` — counters, timer, recordTapInvocation hook in tap closure, stop()-time report
- `ARCHITECTURE.md` — note the source-side instrumentation in MicrophoneCapture's file reference

## More Information

- [ADR-0011](0011-audio-writer-instrumentation.md) — the sink-side instrumentation this ADR composes with
- [ADR-0007](0007-structured-logging-and-debug-tab.md) — the Debug tab that surfaces the new warnings to the user in real time
- The 2026-05-30 09:06 incident — empty WAV after 8-minute recording, no writer-level signal, motivated this ADR
