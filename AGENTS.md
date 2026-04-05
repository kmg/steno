# Steno

Native macOS transcription app. Swift/SwiftUI, Apple Silicon, macOS 14.2+.

## Build

```bash
xcodegen generate
open Steno.xcodeproj
```

Build: Cmd+B. Run: Cmd+R. Test: Cmd+U.

## Dependencies

- **WhisperKit** (argmaxinc/WhisperKit) — transcription via Core ML
- **FluidAudio** (FluidInference/FluidAudio) — speaker diarization (added later)

## Architecture

```
Steno/
  StenoApp.swift    — app entry point
  Audio/            — capture, mixing, pipeline, file writing
  Models/           — Codable data types (Session, Transcript, etc.)
  Services/         — business logic (SessionStore, TranscriptionEngine, etc.)
  Views/            — SwiftUI views
```

## Conventions

- `@StateObject` services injected via `@EnvironmentObject`
- Models are Codable structs
- Services are ObservableObject classes
- File storage: ~/Transcripts/ with JSON + .m4a per session
