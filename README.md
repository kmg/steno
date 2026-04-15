# Steno — Local Meeting Transcription for macOS

Offline meeting transcription for Mac. No cloud, no accounts, no network calls — ever. Once the model downloads, Steno runs fully air-gapped on Apple Silicon.

Record both sides of Zoom, Meet, or Teams calls. Transcribe on-device using OpenAI's [Whisper](https://github.com/openai/whisper) speech-to-text model, with support for [99 languages](https://github.com/openai/whisper#available-models-and-languages). Identifies who said what using on-device speaker recognition. Plain files you own — no database, no proprietary format.

## What it does

1. Press record. Captures both sides of the conversation.
2. Words appear live as people speak.
3. Press stop. Audio saved as .m4a, transcript as JSON with timestamps and speaker labels.
4. Browse past sessions. Re-transcribe anytime with a different model.

Recordings go to `~/Documents/Steno/`. Plain folders, plain files. No database.

## Install

```bash
brew tap kmg/steno
brew install --cask steno
```

Or download the [latest DMG](https://github.com/kmg/steno/releases/latest) directly.

### Permissions

- **Microphone** — prompted automatically on first recording
- **Screen & System Audio Recording** — required for capturing system audio (Zoom, Meet, Teams). Grant in System Settings → Privacy & Security → Screen & System Audio Recording

## Requirements

- macOS 14.2+ (Sonoma)
- Apple Silicon (M1/M2/M3/M4)

## Recording Consent

Steno can record audio from your microphone and system audio. **You are solely responsible for complying with all applicable recording consent laws in your jurisdiction.**

Many jurisdictions require consent from all parties before recording a conversation. In the US, two-party consent states include: California, Connecticut, Florida, Illinois, Maryland, Massachusetts, Montana, New Hampshire, Oregon, Pennsylvania, Vermont, and Washington. See [18 U.S.C. 2511](https://www.law.cornell.edu/uscode/text/18/2511) for federal law.

All audio is processed locally on your device. No recordings are transmitted to the developer or any third party.

## Privacy

- **Audio never leaves your machine.** All transcription runs on Apple Silicon. No audio, transcript text, or file paths are ever transmitted.
- **No meeting bots.** System audio captured via Core Audio Taps — no bot joins your call, no browser extension.
- **Anonymous diagnostics (opt-out).** Steno sends anonymous crash reports and usage events (recording duration, model used, locale) to help improve the app. No audio, no transcripts, no identifying information. Disable in Settings → Privacy & Diagnostics.
- **Your files.** Recordings and transcripts are plain files in `~/Documents/Steno/`. No database, no proprietary format.
- **Open source.** [github.com/kmg/steno](https://github.com/kmg/steno). You can read every line.

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
