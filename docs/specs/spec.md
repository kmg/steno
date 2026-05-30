# Steno — Product Spec

> **Status:** Living document. Update when behavioral changes affect user-visible product surface. Last reviewed: 2026-05-30.
>
> **Implementation references:** `ARCHITECTURE.md` (current data flow + format invariants), `docs/adr/` (decisions, especially [ADR-0004](../adr/0004-audio-architecture-v2.md) for the audio pipeline).

**Record everything. Transcribe locally. Own your data.**

A native macOS app that captures both sides of any conversation — video calls, in-person meetings, phone calls on speaker — and transcribes them locally on your Mac. No cloud. No telemetry. No subscriptions. Your audio never leaves your machine.

## Who This Is For

You're on an M-series Mac running macOS 15.0 or later. You have meetings — video calls, 1:1s, mentorship sessions — and you want a searchable transcript without trusting a cloud service with your audio. You don't want AI summaries or action items. You want the raw transcript with timestamps, and the audio file, in a folder you control.

## What It Does

1. **Press record.** Captures system audio (the remote person on Zoom/Meet/Teams) and your microphone simultaneously.
2. **See the transcript live.** Words appear as the conversation happens.
3. **Press stop.** Audio saved as `.m4a`, transcript saved as JSON with timestamps and confidence scores.
4. **Browse past sessions.** Meeting list shows all recordings — click any to read the transcript.
5. **Re-transcribe anytime.** Pick a different model (faster, more accurate, language-optimized) and re-run on any saved audio.

That's it. No summaries, no meeting detection, no calendar sync, no bots joining your call.

If you want summaries, action items, or follow-ups, point an AI agent at the transcript. The JSON is clean. Steno captures. You decide what to do with it.

## What It Doesn't Do

- No cloud transcription. No "send to OpenAI / Anthropic" toggle. Everything runs on the Neural Engine + Metal GPU.
- No summarization, action items, or meeting intelligence. (May arrive in a future version as a separate, opt-in surface — not the core flow.)
- No calendar integration, no bot that joins your call, no automatic recording. You press record.
- No export to SRT / Word / PDF. The on-disk format is JSON; convert as needed with any tool you like.

## Audio Capture

Two streams, mixed into one recording:

| Stream | What it captures | API |
|--------|-----------------|-----|
| System audio | Remote speakers (Zoom/Meet/Teams output) | Core Audio Taps |
| Microphone | You | AVAudioEngine |

System audio capture uses Core Audio Taps, which require only the "System Audio Recording" permission — narrow, no screen recording indicator in Control Center.

Apple Silicon only — transcription uses the Neural Engine via Core ML, which Intel Macs don't have.

## Transcription

- WhisperKit for speech-to-text. Models range from tiny (39 MB) to large (1.5 GB). Default is large-v3-turbo (~600 MB, recommended for accents and crosstalk).
- 99+ languages supported. Per-window language detection handles code-switching.
- Multiple models can be loaded; re-transcribe any saved session with a different model at any time.

## Speaker Identification

- FluidAudio identifies up to 10 speakers automatically. No configuration.
- Runs on every recording.

## Storage

```
~/Documents/Steno/
  2026-05-30_140023_design-review/
    audio.m4a          # mixed recording (post-arch-v2: WAV during recording, AAC after)
    transcript.json    # segments with timestamps, text, confidence, language, speaker
    metadata.json      # session config, devices, model, transcription history
```

Plain folders. No database. You can browse them in Finder, back them up however you want, grep the JSON. The storage location is configurable.

## UI

Single window with a sidebar of past sessions and a detail pane for the current/selected transcript. Menu bar icon for quick start/stop access when the window is hidden. Settings as a separate window with General + Debug tabs.

The Debug tab (Settings → Debug) shows live application events grouped by subsystem (audio, transcription, diarization, storage, app) — useful for diagnosing why a recording didn't behave as expected. Copy-to-clipboard for sharing diagnostic context.

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘R | Start / stop recording |
| ⌘F | Search sessions (focus the sidebar search field) |
| ⌘⇧C | Copy entire transcript |
| ⌘⌃S | Toggle sidebar |
| ⌘, | Settings |
| ⌘Q | Quit |

## Privacy & Data

- Zero network calls after initial model download. No analytics events, no crash reports, no usage telemetry are sent unless you explicitly opt in via Settings.
- Audio + transcripts never leave your Mac.
- See `README.md` for the full data-handling rundown including the opt-out toggles.

## System Requirements

- **macOS 15.0+** (Sequoia)
- **Apple Silicon** (M1/M2/M3/M4)
- **~4 GB disk** for app + default model + speaker-identification models
- **<2 GB RAM** during transcription

## License

Business Source License 1.1 (BSL 1.1), converting to Apache 2.0 on the change date. See `LICENSE` in the repo root for full terms and the conversion date.
