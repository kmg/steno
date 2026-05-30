# ADR-0004: Audio architecture v2 — WAV during recording, AAC after

* **Status:** Accepted — 2026-05-29 (retroactive; original work landed 2026-04-23)
* **Decision Makers:** Ganesh
* **Supersedes:** Implicit prior decision: record directly to AAC `.m4a` via `AVAudioFile`
* **Last reviewed:** 2026-05-29

## Context and Problem Statement

The original audio pipeline (v0.1.0 through v0.2.14) captured mic via `AVAudioEngine` and system audio via Core Audio Taps, mixed them on the audio thread, and wrote directly to AAC `.m4a` via `AVAudioFile`. This produced four classes of bug that, between them, accounted for the v0.2.11–v0.2.14 release incident (4 broken releases in one session):

1. **Format crashes** — the AAC encoder rejects certain bitrate/sample-rate combos (notably Bluetooth devices at non-standard rates), causing `installTap` to throw `NSException`.
2. **Robotic audio** — mic and system audio at different sample rates, mixed 1:1 at the sample level, produces time-stretched output.
3. **No live system-audio transcription** — feeding mixed audio to WhisperKit broke recording entirely.
4. **Cascading failures** — fixing one bug broke another because everything shared one audio path. A 300-line engine recovery system added in v0.2.11 broke live transcription.

The root cause wasn't any individual bug. It was that the single mixed audio stream and the AAC-encoding-on-the-fly choice were architectural decisions that didn't account for the format diversity of real-world audio devices.

## Decision Drivers

- **Recording reliability is the core function.** Steno's promise is "record everything." Format rejection causing zero audio is the worst possible outcome.
- **AAC encoder fragility is fundamental, not fixable.** No amount of engine-recovery code makes AAC accept Bluetooth's non-standard formats.
- **AVFoundation pipelines that crash mid-stream lose data.** Writing to AAC, when the writer dies, leaves an unreadable file.
- **Mic and system audio have legitimately different sample rates.** Resampling on the audio thread is dangerous (real-time deadline pressure); resampling off-thread is the right answer.
- **The Steer vision (multi-agent meeting intelligence) needs source-tagged audio.** A pre-mixed stream destroys the mic-vs-system signal that diarization could otherwise use.

## Considered Options

### Option 1: Patch the existing single-stream + on-the-fly AAC architecture

Continue fixing crashes as they appear. Add more `installTap` exception catchers, more engine recovery, more format negotiation.

* **Bad:** Already tried. Produced v0.2.11–v0.2.14. Every fix broke something else.
* **Bad:** Doesn't address the root architectural mismatch.

### Option 2: WAV during recording, AAC conversion after recording stops

* Mic + system audio mixed (continued from v1) but written to WAV (LPCM) during recording, not AAC.
* After stop, background `AVAssetExportSession` converts `.wav` → `.m4a`.
* WAV accepts any format — no bitrate negotiation, no encoder rejection.
* If the process crashes, WAV file survives — RIFF header is 44 bytes and can be repaired.

* **Good:** Eliminates the entire class of "AAC encoder rejected this format" crashes.
* **Good:** Crash safety: data survives even if the app dies mid-recording.
* **Good:** Background conversion is non-blocking — UI stays responsive.
* **Neutral:** Disk space: WAV is ~5.6 MB/min mono at 48kHz. 3-hour session = ~1 GB transient. Acceptable on modern Macs; .m4a replaces .wav after conversion.

### Option 3: Two-track recording (separate mic.wav and system.wav)

The fuller version of Option 2: record mic and system to separate WAV files; mix only at export time. Source-tagged transcription (mic = local, system = remote). Diarization gets the source signal for free.

* **Good:** All Option 2 benefits.
* **Good:** Diarization can tag speakers by source without needing acoustic separation.
* **Good:** Different sample rates handled naturally — each file uses its native rate.
* **Bad:** More implementation work (chunks 3-5 of the v2 plan).
* **Bad:** Disk space doubles during recording.

## Decision Outcome

**Selected: Option 2 (chunks 1–2 of the v2 plan), with Option 3 (chunks 3–5) deferred as future work.**

The shipped subset (commit `2fb560a` and follow-ons, released as v0.2.17):

1. **WAV during recording.** `AudioFileWriter` writes LPCM, not AAC.
2. **Format strategy chain for mic capture.** Try `outputFormat(forBus: 0)` → nil → 48kHz mono. Fresh `AVAudioEngine` per attempt. ObjC exception catcher around `installTap`.
3. **Device switch recovery.** Mid-recording device changes (AirPods, Bluetooth, hotplug) restart the engine, resample buffers, concatenate segments.
4. **System audio resampled to mic rate before mixing.** Done on a dispatch queue, off the IO thread, via `AVAudioConverter`.
5. **Mixed audio fed to live transcription** (not mic-only as in v0.2.14).
6. **Post-recording AAC conversion** via `AVAssetExportSession.export(to:as:)` — atomic write to temp file, verify duration, atomic rename.
7. **`ARCHITECTURE.md` as canonical reference** — data flow diagram, format invariants, failure mode map.

### Rationale

- Chunks 1–2 give us crash safety + Bluetooth compatibility — the immediate v0.2.11–v0.2.14 firefight.
- Two-track (chunks 3–5) is the right end state but isn't required to ship the safety improvements.
- Deferring chunks 3–5 keeps the v0.2.17 release scoped. Per [ADR-0005](0005-release-discipline.md), shipping the minimum that fixes the bugs is the discipline.

### Consequences

**Good:**
- v0.2.17 was the first release in 5 weeks. The arch v2 work that made it possible has been tested on device (5 device switches in one recording, no crash, correct audio quality).
- The `audio.wav` survives any failure mode. AAC conversion is best-effort; users never lose audio.
- `ARCHITECTURE.md` is the durable artifact — Claude and Ganesh both read it before touching `Steno/Audio/`.

**Bad:**
- Disk usage during recording is ~5.6 MB/min instead of ~0.5 MB/min. 3-hour session uses ~1 GB transient.
- Post-recording conversion takes time (typically seconds for a 10-minute recording, longer for hours). UX delay is acceptable per the original spec.
- The macOS 15 API choice in `AudioConverter` forced [ADR-0003](0003-macos-15-deployment-target.md) — bumped deployment target.
- Two-track recording (the cleaner end state) is still backlog. Diarization still operates on mixed audio.

## Updates downstream

- `Steno/Audio/AudioFileWriter.swift` — rewritten for WAV
- `Steno/Audio/AudioConverter.swift` — new file, post-recording AAC conversion
- `Steno/Audio/MicrophoneCapture.swift` — format strategy chain
- `Steno/Audio/RecordingPipeline.swift` — device switch recovery, segment concatenation
- `Steno/Audio/SystemAudioCapture.swift` — resampling off the IO thread
- `ARCHITECTURE.md` — data flow + format invariants (canonical reference)
- `.claude/hooks/steno-audio-warning.sh` — fires on `Steno/Audio/` edits
- `.claude/commands/steno-release-test.md` — pre-release checklist

## More Information

- `ARCHITECTURE.md` in this repo — the data flow diagram and format invariants that this architecture enforces.
- [ADR-0003](0003-macos-15-deployment-target.md) — the deployment-target bump forced by `AudioConverter`'s API choice.
- [ADR-0005](0005-release-discipline.md) — the "minimal fix, don't bundle" rule that scoped this work to chunks 1–2.
- The deferred work (chunks 3–5: two-track recording, source-tagged transcription, VBx diarization, live system audio) is tracked in the project's backlog.
