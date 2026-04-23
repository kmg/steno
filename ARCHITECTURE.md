# Steno Audio Architecture

Current state as of v0.2.14. This document is the reference for anyone (human or agent) modifying the audio pipeline. Read before changing files in `Steno/Audio/` or `Steno/Services/StreamingTranscriber.swift`.

## Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                     RecordingPipeline.start()                   │
│                                                                 │
│  MicrophoneCapture                SystemAudioCapture             │
│  (AVAudioEngine)                  (Core Audio Tap)              │
│  installTap → PCMBuffer          IO proc → AudioBufferList      │
│       │                                │                        │
│       │                                ▼                        │
│       │                          AudioMixer                     │
│       │                          .samplesFromBufferList()       │
│       │                                │                        │
│       │                                ▼                        │
│       │                          AudioSharedState               │
│       │                          .appendSystemSamples()         │
│       │                                                         │
│       ▼                                                         │
│  mic.bufferHandler closure                                      │
│       │                                                         │
│       ├──► StreamingTranscriber.appendBuffer(buffer)            │
│       │    (receives MIC ONLY — not mixed)                      │
│       │    resamples to 16kHz mono → WhisperKit                 │
│       │                                                         │
│       └──► if systemAudioActive:                                │
│                consumeSystemSamples(count: frameCount)           │
│                AudioMixer.mix(mic, system) → mixedBuffer        │
│                AudioFileWriter.append(mixedBuffer)               │
│            else:                                                │
│                AudioFileWriter.append(buffer)  ← mic only       │
│                                                                 │
│  AudioFileWriter                                                │
│  writes AAC .m4a at mic's outputFormat                          │
└─────────────────────────────────────────────────────────────────┘
```

**Key fact:** The .m4a file has mixed audio (mic + system). Live transcription has mic only. Re-transcription from the .m4a captures both.

## Format Invariants

These rules MUST hold. Violating any of them produces crashes, robotic audio, or silent data loss.

### 1. installTap format = outputFormat(forBus: 0)

```swift
let format = inputNode.outputFormat(forBus: 0)  // CORRECT
// let format = inputNode.inputFormat(forBus: 0)  // WRONG — hardware format, differs on Bluetooth
```

`outputFormat` returns the engine's processing format. `inputFormat` returns the raw hardware format (e.g., 16kHz for Bluetooth HFP vs 48kHz engine processing). Using `inputFormat` causes sample rate mismatch: mic delivers at 16kHz, system audio at 48kHz, mixer zips 1:1 → robotic time-stretched audio.

Learned 2026-04-22: `inputFormat` caused robotic audio in v0.2.16. Reverted.

### 2. AudioFileWriter format = mic's outputFormat

The writer is opened with `mic.inputFormat` (which is `outputFormat(forBus: 0)` — see rule 1). Every buffer appended must match this format. Mismatched buffers are dropped (format validation in `append`).

### 3. System audio and mic may have different sample rates

The system audio tap reports its own format (e.g., 24kHz stereo on Bluetooth, 48kHz stereo on speakers). The mixer converts system audio to mono via `samplesFromBufferList`. The pipeline then consumes `frameCount` system samples per mic callback.

**Hazard:** If mic is at 48kHz and system audio is at 24kHz, consuming `frameCount` system samples per `frameCount` mic samples mixes different durations of audio. This is a known limitation — proper resampling is needed for correct mixing. Current behavior: system audio plays at wrong speed when sample rates differ.

### 4. AAC bitrate must be compatible with sample rate

128kbps AAC is not supported at all sample rates (e.g., 24kHz Bluetooth). The writer tries 128kbps first, falls back to system default.

### 5. installTap throws NSException, not Swift Error

`installTap(onBus:bufferSize:format:block:)` throws ObjC NSException for:
- Format mismatch (tap format != hardware capability)
- Duplicate tap (tap already installed on bus)

Swift `try/catch` cannot catch NSException. Use `ObjCExceptionCatcher.catching {}` wrapper. Always call `removeTapSafely()` before `installTap` to prevent duplicate tap.

## Thread Safety Map

### Audio IO thread (real-time, must not block)

These closures run on Core Audio's IO thread:
- `MicrophoneCapture.bufferHandler` — the mic tap callback
- `SystemAudioCapture.bufferHandler` — the IO proc callback

Rules:
- No `self` captures of any `@MainActor` or actor-isolated class
- Use explicit local variable captures (not capture lists with `self`)
- No heap allocation if avoidable (performance, not correctness)
- Lock-hold time must be minimal

### Shared mutable state (NSLock protected)

| Class | Lock | Accessed from |
|-------|------|---------------|
| AudioSharedState | `lock` | System audio IO thread (append), mic callback (consume) |
| AudioFileWriter | `lock` | Mic callback (append), main thread (start/finish) |
| StreamingTranscriber | `lock` | Mic callback (appendBuffer), async task (transcribe) |

### Main thread only

- RecordingManager — all @Published state
- UI state updates

## What Breaks What

| If you change... | It may break... | How |
|-----------------|----------------|-----|
| Mic tap format | AudioFileWriter | Writer expects the format it was opened with. Mismatched buffers are dropped or produce corrupt audio. |
| Mic tap format | StreamingTranscriber | Transcriber resamples internally, so format changes are usually safe. But if buffer structure changes (e.g., interleaved vs non-interleaved), `appendBuffer` may read garbage. |
| What StreamingTranscriber receives | Live transcription | Currently receives mic-only. Changing to mixed requires verifying the mixed buffer format matches what `appendBuffer` expects. |
| AudioMixer mixing logic | .m4a recording quality | Ducking, clipping, sample alignment all affect the recorded file. |
| AudioSharedState timing | System audio in recording | Stale sample detection (500ms timeout) discards old system samples. Changing the timeout or removal logic affects mixing. |
| SystemAudioCapture tap setup | System audio availability | Tap creation is fragile — permission-dependent, device-graph-dependent. Changes may silently fail. |
| AudioFileWriter encoding settings | Recording on specific devices | AAC bitrate, sample rate, channel count must be compatible. Bluetooth devices have narrow format support. |

## Known Limitations

1. **Live transcription = mic only.** The StreamingTranscriber receives the raw mic buffer, not the mixed buffer. System audio (remote speakers in calls, YouTube, etc.) is only in the .m4a file, accessible via re-transcription.

2. **No sample rate resampling in mixer.** When mic and system audio have different sample rates (common with Bluetooth), the mixer zips samples 1:1 which stretches or compresses one stream. Fix requires resampling system audio to mic rate before mixing.

3. **No device change recovery.** If the mic device changes mid-recording (AirPods connect/disconnect), the engine may stop delivering buffers. The ObjC exception catcher prevents crashes but doesn't restart the engine. The recording captures whatever was recorded before the change.

4. **Writer starts after mic.** First 1-2 mic callbacks (~170ms) are dropped because the writer isn't ready yet. The mic must start first to determine its format for the writer.

## File Reference

```
Steno/Audio/
  MicrophoneCapture.swift    — AVAudioEngine mic input, installTap
  SystemAudioCapture.swift   — Core Audio Tap, aggregate device, IO proc
  AudioMixer.swift           — RMS ducking, stereo-to-mono, sample mixing
  AudioFileWriter.swift      — AAC .m4a writer with bitrate fallback
  AudioSharedState.swift     — NSLock ring buffer between system audio and mic callback
  RecordingPipeline.swift    — orchestrates all of the above
  ObjCExceptionCatcher.h/.m  — NSException → NSError bridge for installTap
  HighPassFilter.swift       — not currently wired into pipeline
  Normalizer.swift           — not currently wired into pipeline

Steno/Services/
  RecordingManager.swift     — @MainActor UI state, delegates to RecordingPipeline
  StreamingTranscriber.swift — accumulates mic PCM, feeds WhisperKit for live transcription
  TranscriptionEngine.swift  — WhisperKit model management, batch transcription
  DiarizationManager.swift   — FluidAudio LS-EEND speaker identification
```
