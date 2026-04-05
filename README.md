# Steno

Record meetings on your Mac. Transcribe locally. No cloud, no bots, no accounts.

## What it does

1. Press record. Captures your mic and system audio (Zoom, Meet, Teams) simultaneously.
2. Words appear live as the conversation happens.
3. Press stop. Audio saved as .m4a, transcript as JSON with timestamps and speaker labels.
4. Browse past sessions. Click any to read the transcript.

Recordings go to `~/Documents/Steno/`. Plain folders, plain files. No database.

## Install

```bash
brew tap kmg/steno
brew install --cask steno
```

Or download the [latest DMG](https://github.com/kmg/steno/releases/latest) directly.

### First launch (unsigned app)

Steno is not notarized. macOS will block it on first launch:

1. Open the DMG and drag Steno to Applications
2. Double-click Steno — macOS shows "Steno Not Opened" → click **Done**
3. Open **System Settings → Privacy & Security** → scroll to Security
4. Click **Open Anyway** next to "Steno was blocked"
5. Confirm the dialog → authenticate with Touch ID or password
6. Allow Documents folder access when prompted

After this, Steno opens normally.

### Permissions

- **Microphone** — prompted automatically on first recording
- **Screen & System Audio Recording** — required for capturing system audio (Zoom, Meet, Teams). Grant in System Settings → Privacy & Security → Screen & System Audio Recording

## Requirements

- macOS 14.2+ (Sonoma)
- Apple Silicon (M1/M2/M3/M4)

## Extending

Steno outputs clean JSON. It doesn't summarize, generate action items, or integrate with anything. That's by design.

```json
{
  "segments": [
    {"start": 0.0, "end": 3.5, "text": "Let's start with the architecture review", "speaker": "SPEAKER_1"},
    {"start": 3.8, "end": 8.1, "text": "Sure, pulling it up now.", "speaker": "SPEAKER_0"}
  ]
}
```

Point any tool at this. Claude Code, Codex, a shell script, grep. The transcript is yours to do what you want with.

## Design

Unix philosophy. One tool, one job. Record and transcribe. Nothing else.

- **Local only.** No network calls after initial model download. No analytics, no telemetry, no update checks.
- **No bot joins your call.** System audio captured via Core Audio Taps. The other participants never know.
- **Speaker identification.** FluidAudio ML identifies up to 10 speakers automatically. Runs on the Neural Engine.
- **Custom models.** Convert any fine-tuned Whisper model to Core ML with [whisperkittools](https://github.com/argmaxinc/whisperkittools). Point Steno at the folder in Settings.
- **Crash safe.** Audio and partial transcripts survive force-quits. Recovered on next launch.

## Architecture

| Component | Technology |
|-----------|-----------|
| Language | Swift |
| UI | SwiftUI |
| System audio | Core Audio Taps (macOS 14.2+) |
| Microphone | AVAudioEngine |
| Transcription | [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Core ML, Neural Engine) |
| Speaker ID | [FluidAudio](https://github.com/FluidInference/FluidAudio) (Core ML) |
| Storage | File system + JSON |

Two dependencies. Both open source. MIT and Apache 2.0.

## Build from source

```bash
brew install xcodegen
git clone https://github.com/kmg/steno.git
cd steno
xcodegen generate
open Steno.xcodeproj
```

## License

MIT
