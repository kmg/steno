# ADR-0013: Core Audio listener registration once per instance lifetime

* **Status:** Accepted — 2026-05-30
* **Decision Makers:** Ganesh
* **Supersedes:** Implicit prior pattern: register listener in `start()`, remove in `stop()`
* **Last reviewed:** 2026-05-30

## Context and Problem Statement

The 2026-05-30 triple-device torture test on v0.2.19 (AirPods → Bose → built-in, three switches mid-recording) ran cleanly at the audio level but surfaced a steady leak in the Debug-tab log. The `Default input device changed` and `Default output device changed` log lines fired in **growing duplicates** with each device transition:

| Time | Output events | Input events |
|---|---|---|
| 18:48:22 (app launch) | 3 | 3 |
| 18:48:39 | 3 | 3 |
| 18:49:09 (first switch) | 4 | 4 |
| 18:50:20 (second switch) | 5 | 5 |
| 18:51:02 (after stop) | 6 | 6 |

+1 per restart cycle. After enough sessions in one app run, every system device change fires dozens of listener callbacks, each scheduling a redundant restart attempt. The `pendingRestart` cancellation prevents extra actual restarts, but the listener callbacks still execute, log, and dispatch work — wasting cycles and confusing diagnostics.

## Decision Drivers

- **Root cause:** the previous pattern registered a new `AudioObjectPropertyListenerBlock` at the end of each `start()` and removed it at the start of each `stop()`. The Swift-to-ObjC block bridging makes `AudioObjectRemovePropertyListenerBlock` unreliable — the bridged ObjC block instance passed at register time can differ from the stored block instance, so removal silently fails. Each restart cycle re-registers without truly removing the previous listener.
- **The torture test data is conclusive:** monotonic growth means duplicates are NOT a Core Audio quirk (which would be a fixed multiplier) but a per-cycle leak from our code.
- **Recording correctness is unaffected** — only one restart fires per device change because of the `pendingRestart` debounce, and the duplicate log lines aren't user-facing. But the leak is a real cost: memory, redundant callbacks, and noisier diagnostics that obscure real signal.

## Considered Options

### Option 1: Status quo — install in `start()`, remove in `stop()`

* **Bad:** Demonstrated to leak. Each cycle adds a listener that removal can't reliably clean up.

### Option 2: Wrap the listener block in an Objective-C class

The classic workaround for the Swift-to-ObjC block bridging issue: define `@objc class ListenerWrapper { let block: AudioObjectPropertyListenerBlock }` and pass `wrapper.block` consistently.

* **Good:** Preserves the install-on-start / remove-on-stop symmetry.
* **Bad:** Adds an Objective-C bridging type to a Swift-only codebase. Doesn't fundamentally change that registration is a side effect with subtle ordering.
* **Bad:** Doesn't address the underlying observation that the listener doesn't actually need to be lifecycle-bound to a single recording.

### Option 3: Register once per instance lifetime, gate the body with `isCapturing`

The listener registers in `init()` and removes in `deinit`. Inside the listener block, an `isCapturing` guard short-circuits when not recording. `start()` and `stop()` never touch the listener.

* **Good:** Removes the leak entirely — registration happens at most once per instance, and `RecordingPipeline` holds exactly one `SystemAudioCapture` and one `MicrophoneCapture` for its lifetime.
* **Good:** Eliminates the noisy "device changed" log lines when not recording (the guard returns before the log fires).
* **Good:** Symmetric across `SystemAudioCapture` and `MicrophoneCapture` — same pattern works for both.
* **Neutral:** The listener is "always on" rather than "registered when needed." For a tap-based audio capture component, the cost is negligible.

## Decision Outcome

**Selected: Option 3.**

### Implementation summary

In both `SystemAudioCapture` and `MicrophoneCapture`:

```swift
init() {
    install<Output|Input>DeviceListener()  // once per instance
}

deinit {
    stop()
    remove<Output|Input>DeviceListener()   // cleanup
}

private func install<...>DeviceListener() {
    // ... let block = { [weak self] _, _ in
    //     guard let self else { return }
    //     guard self.isCapturing else { return }  // ← THE KEY CHANGE
    //     self.log.info("Default <...> device changed")
    //     // ... schedule restart on restartQueue ...
    // }
    let status = AudioObjectAddPropertyListenerBlock(..., block)
    if status == noErr { deviceListenerBlock = block }
}
```

`start()` and `stop()` no longer reference the listener. The `pendingRestart` debounce logic stays inside the listener block — that's about coalescing rapid notifications, not about lifecycle.

### Rationale

- The leak's root cause is in Swift block bridging, not in our lifecycle logic. The cleanest fix is to make lifecycle irrelevant: register once, never re-register.
- The `isCapturing` gate keeps the listener cheap when not in a recording state — same observable behavior as "listener not registered," at the cost of one boolean check per system notification.
- `RecordingPipeline` instantiates `SystemAudioCapture` and `MicrophoneCapture` once and holds them for the app lifetime. The "register in init, remove in deinit" pattern matches that lifecycle naturally.

### Consequences

**Good:**
- Listener counts stay at 1 per instance, forever. No growth across recordings.
- "Default device changed" log lines fire only during active recording, matching user intent — diagnostics get quieter and more meaningful.
- Pattern transfers directly to any future Core Audio listener registration.

**Bad:**
- The listener is registered even when no recording is active. Memory cost is negligible (one block per instance, instances live forever during app run).
- System notifications still fire and the listener still runs, just to exit at the `isCapturing` guard. Tiny CPU cost.
- A subclass / replacement instance can't change the behavior partway through — the listener is tied to the instance, and the instance lives for the app run.

## Updates downstream

- `Steno/Audio/SystemAudioCapture.swift` — listener install moved from end of `start()` to `init()`, removal moved from `stop()` to `deinit`, gate added in block body.
- `Steno/Audio/MicrophoneCapture.swift` — same pattern.
- `MicrophoneCapture` had a defensive `removeInputDeviceListener()` call at the start of `installInputDeviceListener()`. That's now redundant (only called once from init) and removed.

## More Information

- [ADR-0011](0011-audio-writer-instrumentation.md), [ADR-0012](0012-microphone-capture-instrumentation.md) — the prior instrumentation pattern that surfaced this leak via the Debug tab.
- The 2026-05-30 torture-test log — the proximate evidence for the leak's monotonic growth.
