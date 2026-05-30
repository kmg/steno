# Steno Audio Architecture

Current state as of v0.2.17 (arch v2, chunk 1). This document is the reference for anyone (human or agent) modifying the audio pipeline. Read before changing files in `Steno/Audio/` or `Steno/Services/StreamingTranscriber.swift`.

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
│       ├──► MicResampler.resample(buffer)                        │
│       │    (converts to writer format if device changed)        │
│       │                                                         │
│       └──► if systemAudioActive:                                │
│                consumeSystemSamples(count: frameCount)           │
│                  ↳ resamples system audio to mic rate            │
│                    via vDSP_vlint interpolation                  │
│                AudioMixer.mix(mic, system) → mixedBuffer        │
│                StreamingTranscriber.appendBuffer(mixedBuffer)    │
│                AudioFileWriter.append(mixedBuffer)               │
│            else:                                                │
│                StreamingTranscriber.appendBuffer(buffer)         │
│                AudioFileWriter.append(buffer)  ← mic only       │
│                                                                 │
│  AudioFileWriter                                                │
│  writes WAV (LPCM) at mic's outputFormat                        │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│               POST-RECORDING (background thread)                │
│                                                                 │
│  AudioConverter.convertToAAC(wavURL:)                           │
│  audio.wav → audio.m4a (AAC via AVAssetExportSession)           │
│  Deletes .wav after verified conversion                         │
└─────────────────────────────────────────────────────────────────┘
```

**Key facts:**
- During recording: `audio.wav` (LPCM) on disk. WAV accepts any format — no bitrate errors.
- After recording: `audio.m4a` (AAC) replaces .wav. If conversion fails, .wav survives.
- The .m4a/.wav file has mixed audio (mic + system).
- Live transcription receives the mixed buffer — captures both speakers.
- System audio is resampled to mic rate before mixing (handles Bluetooth rate differences).
- Mic device changes mid-recording are handled: engine restarts, buffers resampled to writer format.
- `SessionStore.audioFileURL` prefers .m4a, falls back to .wav.

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

### 3. System audio resampled to mic rate before mixing

The system audio tap reports its own format (e.g., 24kHz stereo on Bluetooth, 48kHz stereo on speakers). `AudioSharedState.consumeSystemSamples` resamples system audio to match the mic's frame count using `vDSP_vlint` linear interpolation. The rate is set at recording start and updated automatically when devices change.

When rates differ, the correct number of system samples is consumed (based on the rate ratio) and interpolated to the mic's frame count. This produces correctly-timed mixed audio regardless of device sample rates.

### 4. AAC bitrate compatibility (post-recording conversion only)

During recording, audio is written as WAV/LPCM — no bitrate negotiation needed. AAC encoding happens post-recording via `AudioConverter` using `AVAssetExportPresetAppleM4A`, which handles bitrate/sample rate automatically. This eliminates the class of bugs where AAC rejected certain format combinations during live recording.

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
| AudioFileWriter encoding settings | Recording on specific devices | Writer uses LPCM (accepts anything). Post-recording AAC conversion handles format negotiation automatically. |

## Known Limitations

1. **Brief gap on device switch.** When mic or system audio device changes mid-recording, there's a ~200-500ms gap while the engine restarts. Audio before and after the switch is captured correctly.

4. **Writer starts after mic.** First 1-2 mic callbacks (~170ms) are dropped because the writer isn't ready yet. The mic must start first to determine its format for the writer.

5. **WAV crash recovery.** If the app crashes during recording, the WAV data is on disk but the RIFF header has incorrect size fields (written on close). `CrashRecovery.repairWAVHeader` patches bytes 4-7 (RIFF chunk size) and 40-43 (data subchunk size) from the actual file size. After repair, background conversion to AAC runs automatically.

## File Reference

```
Steno/Audio/
  MicrophoneCapture.swift    — AVAudioEngine mic input, installTap
  SystemAudioCapture.swift   — Core Audio Tap, aggregate device, IO proc
  AudioMixer.swift           — RMS ducking, stereo-to-mono, sample mixing
  AudioFileWriter.swift      — WAV/LPCM writer (NSLock-protected)
  AudioConverter.swift       — post-recording WAV → AAC conversion
  AudioSharedState.swift     — NSLock ring buffer with sample rate resampling (vDSP_vlint)
  RecordingPipeline.swift    — orchestrates all of the above
  ObjCExceptionCatcher.h/.m  — NSException → NSError bridge for installTap
  HighPassFilter.swift       — not currently wired into pipeline
  Normalizer.swift           — not currently wired into pipeline

Steno/Services/
  RecordingManager.swift     — @MainActor UI state, delegates to RecordingPipeline
  StreamingTranscriber.swift — accumulates mic PCM, feeds WhisperKit for live transcription
  TranscriptionEngine.swift  — WhisperKit model management, batch transcription
  DiarizationManager.swift   — FluidAudio LS-EEND speaker identification
  Logging/
    StenoLog.swift           — facade: StenoLog.audio.info("..."), 5 subsystems
    LogStore.swift           — NSLock-protected ring buffer feeding the Debug tab
```

## Logging

All code logs via `StenoLog.<subsystem>.<level>(message)`. Subsystems: `audio`, `transcription`, `diarization`, `storage`, `app`. Each call writes to `os_log` (Console.app, `log stream`) AND to `LogStore.shared` (in-app Debug tab in Settings).

See [ADR-0007](docs/adr/0007-structured-logging-and-debug-tab.md) for the design.

**Don't use bare `Logger(subsystem:category:)` in app code.** It bypasses LogStore and the Debug tab can't show it. The one exception is `StenoLog` itself, which wraps `os.Logger` internally.
