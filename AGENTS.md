# Steno

Native macOS transcription app. Swift/SwiftUI, Apple Silicon, macOS 14.2+.

## Build

```bash
xcodegen generate
open Steno.xcodeproj
```

Build: Cmd+B. Run: Cmd+R. Test: Cmd+U.

## Release

```bash
# bump MARKETING_VERSION in project.yml
git commit && git push
git tag v0.X.Y && git push origin v0.X.Y
```

GitHub Actions builds DMG, creates release. Then update SHA256 in `kmg/homebrew-steno`.

## Dependencies

- **WhisperKit** (argmaxinc/WhisperKit) — transcription via Core ML
- **FluidAudio** (FluidInference/FluidAudio) — speaker identification via Core ML

## Architecture

```
Steno/
  StenoApp.swift        — app entry point
  Audio/
    MicrophoneCapture   — AVAudioEngine input tap
    SystemAudioCapture  — Core Audio Taps (macOS 14.2+)
    AudioMixer          — RMS ducking, clipping prevention
    AudioFileWriter     — AVAudioFile → AAC .m4a
    AudioSharedState    — thread-safe buffer for audio IO threads
  Models/               — Codable data types (Session, Transcript, Speaker)
  Services/
    RecordingManager    — orchestrates mic + system audio + streaming + writing
    TranscriptionEngine — WhisperKit wrapper, model management
    StreamingTranscriber — live transcription during recording
    DiarizationManager  — FluidAudio speaker identification
    SessionStore        — ~/Documents/Steno/ file management
    CrashRecovery       — recovers interrupted sessions on launch
  Views/                — SwiftUI (NavigationSplitView, MenuBarExtra, Settings)
```

## Conventions

- `@StateObject` services injected via `@EnvironmentObject`
- Models are Codable structs
- Services are ObservableObject classes
- File storage: ~/Documents/Steno/ with JSON + .m4a per session

## Lessons Learned

### Swift 6 actor isolation on audio threads

`@MainActor` class closures running on Core Audio IO threads crash on ANY `self` access — even `self?.property` via optional chaining. Swift 6 strict concurrency enforces actor isolation at runtime with `_dispatch_assert_queue_fail`.

**Fix:** Use a separate `@unchecked Sendable` class (`AudioSharedState`) for state shared between audio threads. Capture all tools (mixer, writer) as local variables BEFORE the closure. The closure must have zero references to `self`.

```swift
// WRONG — crashes on audio thread
systemCapture.bufferHandler = { [weak self] bufferList in
    self?.systemSampleBuffer.append(contentsOf: samples)  // CRASH
}

// RIGHT — no self access
let state = self.sharedState  // AudioSharedState: @unchecked Sendable
systemCapture.bufferHandler = { bufferList in
    state.appendSystemSamples(samples)  // safe, non-actor class
}
```

### AVAudioFile over AVAssetWriter for recording

AVAssetWriter requires CMSampleBuffer conversion from AVAudioPCMBuffer — fragile, produces 0-byte files. AVAudioFile writes PCM→AAC directly with `file.write(from: buffer)`. Simpler, reliable.

### WhisperKit AudioStreamTranscriber owns its own AVAudioEngine

Can't use `AudioStreamTranscriber` alongside your own `MicrophoneCapture` — two AVAudioEngine instances on the same input node conflict. Build a custom streaming loop: accumulate Float samples from mic callback, periodically call `whisperKit.transcribe(audioArray:)`.

### macOS app icon needs all 10 sizes

A single 1024px PNG doesn't get the squircle mask. Provide all sizes (16, 32, 64, 128, 256, 512, 1024) with correct Contents.json mapping. Use `sips -z` to generate from source, `pngquant` to optimize.

### GitHub Actions release workflow

- Use `macos-15` runner (not `macos-14`)
- Explicit `sudo xcode-select -s /Applications/Xcode_16.2.app`
- `xcodebuild -resolvePackageDependencies` step before build
- Enable **Settings → Actions → General → Workflow permissions → Read and write**
