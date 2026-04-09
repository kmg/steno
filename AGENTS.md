# Steno

Native macOS transcription app. Swift/SwiftUI, Apple Silicon, macOS 14.2+.

## Build

```bash
xcodegen generate
open Steno.xcodeproj
```

Build: Cmd+B. Run: Cmd+R. Test: Cmd+U.

CI uses Xcode 16.2 (macOS 15 SDK). Local dev may use a newer Xcode — don't assume a local Release build validates the CI build.

## Release

```bash
# bump MARKETING_VERSION in project.yml
git commit && git push
git tag v0.X.Y && git push origin v0.X.Y
```

GitHub Actions builds DMG, creates release. Then update SHA256 in `kmg/homebrew-steno`.

### CI Signing: Entitlements Are Required

The release workflow signs with `codesign --options runtime` (hardened runtime). **This strips all permissions unless `--entitlements` is passed explicitly.** The entitlements file (`Steno/Steno.entitlements`) must be passed to the codesign step — without it, macOS silently denies microphone access. No error, no prompt, the app just doesn't transcribe.

This broke v0.2.0–v0.2.2. The code was unchanged, the build succeeded, the app launched fine — but the core feature silently didn't work. If transcription ever stops working after a CI-only change, check entitlements first.

## Dependencies

- **WhisperKit** (argmaxinc/WhisperKit) — transcription via Core ML
- **FluidAudio** (FluidInference/FluidAudio) — speaker identification via Core ML
- **Sentry** (getsentry/sentry-cocoa) — crash reporting (opt-out)
- **PostHog** (PostHog/posthog-ios) — anonymous usage analytics (opt-out)

## Architecture

```
Steno/
  StenoApp.swift        — app entry point, first-launch gating
  Audio/
    MicrophoneCapture   — AVAudioEngine input tap
    SystemAudioCapture  — Core Audio Taps (macOS 14.2+)
    AudioMixer          — RMS ducking, clipping prevention
    AudioFileWriter     — AVAudioFile → AAC .m4a (NSLock-protected)
    AudioSharedState    — thread-safe buffer for audio IO threads (NSLock-protected)
    RecordingPipeline   — non-actor class owning all audio-thread work
  Models/               — Codable data types (Session, Transcript, Speaker)
  Services/
    RecordingManager    — @MainActor, holds @Published UI state only
    TranscriptionEngine — WhisperKit wrapper, model management
    StreamingTranscriber — live transcription during recording (NSLock-protected)
    Analytics           — Sentry + PostHog wrapper, event helpers
    UpdateChecker       — GitHub Releases version check
    DiarizationManager  — FluidAudio speaker identification
    SessionStore        — ~/Documents/Steno/ file management
    CrashRecovery       — recovers interrupted sessions on launch
  Views/                — SwiftUI (NavigationSplitView, MenuBarExtra, Settings)
    WelcomeView         — first-launch onboarding (model picker, permissions)
```

## Conventions

- `@StateObject` services injected via `@EnvironmentObject`
- Models are Codable structs
- Services are ObservableObject classes
- File storage: ~/Documents/Steno/ with JSON + .m4a per session
- Audio-thread closures: zero `self` references, explicit local captures only
- All cross-thread mutable state behind NSLock (not actors — NSLock can't be used in async contexts)

## Action-Side-Effect Checklist

Before shipping any view change, trace every user action through the full loop:

1. **Every Button**: what happens on success? On failure? Does the user see both?
2. **Every Toggle**: does the change take effect immediately? Is the system it controls notified?
3. **Every async action**: is there a loading state? What if the view disappears mid-task?
4. **Every onChange**: should it fire on every change, or only on commit? (TextField onChange fires per keystroke — use a button instead for expensive operations like model loading)
5. **Every delete/remove**: does it clean up all related state (files, index, selection)?

The pattern: **trigger → state change → side effect → user feedback → error path.** Most bugs are missing feedback or missing error paths.

## Thread Safety Rules

Audio IO threads (mic callback, system audio IO proc) run outside any actor. Code on these threads must:
1. Never access `self` of any `@MainActor` or actor-isolated class
2. Use explicit local variable captures in closures (not capture lists with `self`)
3. Protect shared mutable state with NSLock (AudioSharedState, AudioFileWriter, StreamingTranscriber)
4. Keep lock-hold time minimal — do work outside the lock, lock only for reads/writes

## WhisperKit Notes

- Model names use underscores: `large-v3_turbo` not `large-v3-turbo` (matches HuggingFace directory `openai_whisper-large-v3_turbo`)
- 30-second windows are hardcoded in the model architecture (480,000 samples at 16kHz)
- `usePrefillPrompt: false, detectLanguage: true` enables per-window language detection for mixed-language audio
- Streaming transcriber sends full accumulated buffer (not windowed) — language detection is less reliable for live

## macOS App Icon

Use asset catalog only — no `.icns` file, no `CFBundleIconFile` in Info.plist. Set `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` in build settings. macOS applies squircle mask automatically.

## GitHub Actions

- `macos-15` runner with `sudo xcode-select -s /Applications/Xcode_16.2.app`
- `xcodebuild -resolvePackageDependencies` step before build
- Enable Settings → Actions → General → Workflow permissions → Read and write
