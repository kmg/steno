# Steno

Native macOS transcription app. Swift/SwiftUI, Apple Silicon, macOS 15.0+.

## Clean-Room Engineering

All code is written from Apple's documentation, framework APIs, and first principles. Do not copy implementations from other projects. Do not reference external apps, competitors, or third-party projects in code comments, commit messages, or documentation. When solving a problem, design from the platform APIs — not by mirroring how another app does it.

## Release Discipline

Learned 2026-04-21: shipped 4 broken releases (v0.2.11–v0.2.14) in one session trying to fix a device-switch crash. A 300-line engine recovery system broke live transcription — the core feature. The actual fix was two one-liners.

**Rules:**

1. **Minimal fix, then stop.** Fix the reported bug. Don't rewrite the subsystem. Don't fix 15 audit issues in one commit. Ship the smallest change that addresses the crash, confirm it works, move on.

2. **Test a full recording before tagging.** Not "it compiles." Not "the unit test passes." Record a real 3-minute meeting, verify transcription flows continuously, then tag. If you can't test on device, don't ship.

3. **Don't bundle unrelated changes.** The streaming transcriber sliding window had nothing to do with the device-switch crash. It was an "improvement" that broke transcription at 90 seconds. One bug, one fix, one release.

4. **Research before implementing, not after shipping.** We shipped the device change handler, then researched how other apps do it. Invert that order.

5. **Protect the core function above all else.** Steno records and transcribes. Every change must be evaluated against: "does this break recording or transcription?" If unsure, don't ship it.

## Read first

- `docs/adr/` — architecture decision records (MADR format). Read [0001](docs/adr/0001-record-architecture-decisions.md) and [0002](docs/adr/0002-madr-format.md) for the system; read [0004](docs/adr/0004-audio-architecture-v2.md), [0005](docs/adr/0005-release-discipline.md), and [0006](docs/adr/0006-v0.1.x-retroactive-decisions.md) before touching anything substantive.
- `ARCHITECTURE.md` — data flow, format invariants, what-breaks-what map. Required reading before editing `Steno/Audio/` or `Steno/Services/StreamingTranscriber.swift`.

## Architecture Reference

Before modifying any file in `Steno/Audio/` or `Steno/Services/StreamingTranscriber.swift`, read `ARCHITECTURE.md`. It documents the data flow, format invariants, thread safety rules, and what-breaks-what map. Changes that violate the invariants will produce crashes, robotic audio, or silent data loss.

## Recording architecture decisions (ADRs)

Every behavioral change ships with an ADR or amendment, in the same commit. Use [`docs/adr/0001`](docs/adr/0001-record-architecture-decisions.md) and [`0002`](docs/adr/0002-madr-format.md) as the format reference. New ADRs use the next sequential number; superseded ADRs stay in the repo with `Status: Superseded by ADR-NNNN`. Pure UI tweaks, version bumps, and copy edits don't need ADRs — anything that encodes a design rule does.

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

**Notarization auth: App Store Connect API key, not app-specific passwords.** Secrets: `APPLE_API_KEY_P8`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`. Learned the hard way when v0.2.4 was blocked by an Apple ID account-recovery flow that invalidated all app-specific passwords. API keys are tied to the team, not the personal Apple ID, and survive an Apple ID lock.


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
    SystemAudioCapture  — Core Audio Taps
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

## User-Facing Language

**No technical jargon in the UI.** Users don't know what MLX, HuggingFace, tok/s, or model_type means. Rules:
- Say "on your Mac" not "using MLX" or "via Core ML"
- Say "downloads on first use" not "cached at ~/.cache/huggingface/hub/"
- Model names in Settings: use friendly names not HuggingFace IDs
- Error messages: actionable ("Connect to the internet to download") not technical ("NSURLErrorDomain -1009")

Technical details belong in logs (Logger), not in user-visible text.

## Action-Side-Effect Checklist

Before shipping any view change, trace every user action through the full loop:

1. **Every Button**: what happens on success? On failure? Does the user see both?
2. **Every Toggle**: does the change take effect immediately? Is the system it controls notified?
3. **Every async action**: is there a loading state? What if the view disappears mid-task?
4. **Every onChange**: should it fire on every change, or only on commit? (TextField onChange fires per keystroke — use a button instead for expensive operations like model loading)
5. **Every delete/remove**: does it clean up all related state (files, index, selection)?

The pattern: **trigger → state change → side effect → user feedback → error path.** Most bugs are missing feedback or missing error paths.

## SDK Keys

Third-party SDK keys (PostHog `phc_`, Sentry DSN, similar public-by-design vendor keys) **never go inline in `.swift` source.** They live in `Steno.xcconfig` (gitignored), are plumbed into `Info.plist` via `$(VAR)` substitution, and read at runtime via `Bundle.main.infoDictionary?["KeyName"]`.

First-time setup:
```bash
cp Steno.xcconfig.example Steno.xcconfig
# edit Steno.xcconfig with real values, then:
xcodegen generate
```

If `Steno.xcconfig` is missing, the build still works — the SDK init in `Analytics.swift` becomes a no-op with a log message. Useful for CI and contributors.

The linter (`no-inline-sdk-key` rule) flags literal `phc_*`, `phx_*`, `sk-ant-*`, `sk-*`, and Sentry DSN URL patterns in `.swift` files. See [ADR-0009](docs/adr/0009-build-time-config-for-sdk-keys.md).

**Real secrets** (Personal API Keys `phx_`, Anthropic/OpenAI keys `sk-`, signing certs, App Store Connect API keys) never go in any committed file, ever — not even in this pattern. Those belong in environment variables or a secret store outside the repo tree.

## Linter

Custom linter at `tools/lint-steno.swift` enforces several rules mechanically. Run on the codebase:

```bash
./tools/lint-steno.swift Steno/
```

Or on one file. Exit code is `0` clean, `1` violations. Each violation includes a remediation hint Claude should act on.

Rules: `max-file-loc` (500), `no-try-bang` (outside tests), `no-print` (outside tests — use `StenoLog`), `no-bare-logger` (use `StenoLog` outside `Steno/Services/Logging/`), `codable-explicit-coding-keys` (every `Codable` struct/class declares an explicit `CodingKeys`).

When the linter blocks a write, read the `fix:` hint and apply it directly. See [ADR-0008](docs/adr/0008-custom-linter.md). When adding a new structural rule (e.g., from a new ADR), add the enforcement to the linter in the same commit.

## Logging

All app code logs via `StenoLog.<subsystem>.<level>(message)`. The five subsystems are `audio`, `transcription`, `diarization`, `storage`, `app`. Each call writes to `os_log` AND to the in-app Debug tab.

```swift
StenoLog.audio.info("Recording started")
StenoLog.transcription.warning("Model load slow: \(elapsed)s")
StenoLog.storage.error("Session save failed: \(error)")
```

**Do not use bare `Logger(subsystem:category:)` in app code** — it bypasses the Debug tab. See [ADR-0007](docs/adr/0007-structured-logging-and-debug-tab.md).

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
