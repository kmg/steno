# Steno

Your meetings are transcribed by a bot that joined uninvited. The audio lives on someone else's server. You agreed to terms you didn't read. The transcript is accurate enough to be useful and inaccurate enough to misquote you.

Steno does one thing. It records both sides of a conversation on your Mac and transcribes them locally. No cloud. No bot joining your call. No account. The audio never leaves your machine.

## What it does

1. Press record. Captures your microphone and system audio (the other person on Zoom, Meet, Teams) simultaneously.
2. Words appear as you speak. Live transcription runs on your Mac's Neural Engine.
3. Press stop. Audio saved as .m4a, transcript saved as JSON with timestamps.
4. Browse past sessions. Click any to read the full transcript.

That's it. No summaries. No action items. No calendar sync. You get the raw transcript and the audio file, in a folder you control.

## Who this is for

You're on an M-series Mac. You have meetings. You want a searchable transcript without trusting a third party with your audio. You've looked at Otter, Granola, Meetily, and the rest. They're either cloud-dependent, electron-wrapped, or you can't tell what they do with your data.

Steno is 2,500 lines of Swift you can read end to end. Two dependencies. MIT license.

## How audio capture works

Two streams, mixed into one recording:

| Stream | What it captures | How |
|--------|-----------------|-----|
| System audio | Remote speakers (Zoom/Meet/Teams) | Core Audio Taps (macOS 14.2+) |
| Microphone | You | AVAudioEngine |

System audio capture starts automatically. If permission isn't granted or nothing is playing, it falls back to mic-only. No toggle, no configuration.

Core Audio Taps requires only "System Audio Recording" permission. Not screen recording. No purple indicator in Control Center. No monthly re-prompt on Sequoia.

## Speaker identification

Two layers, chosen automatically:

**Video calls.** When system audio is active, Steno knows which stream is you (microphone) and which is the other person (system audio). Labels appear as "You" and "Remote." Zero ML cost.

**In-person meetings.** When everyone is on the same microphone, Steno runs ML-based speaker identification using FluidAudio. Runs on the Neural Engine. Labels appear as "Speaker 1", "Speaker 2", etc.

## Transcription

[WhisperKit](https://github.com/argmaxinc/WhisperKit) runs on your Mac's Neural Engine via Core ML. The `tiny` model (~39MB) ships as default for fast setup. Switch to `large-v3-turbo` (~600MB) in Settings for better accuracy (2% word error rate on LibriSpeech).

Models download on first use from HuggingFace and cache locally. After that, fully air-gapped.

**Custom models.** Convert any fine-tuned Whisper model to Core ML with [whisperkittools](https://github.com/argmaxinc/whisperkittools), point Steno at the output folder in Settings. Useful for language-specific models.

## Where recordings go

```
~/Documents/Steno/
  2026-04-04_210135/
    audio.m4a           — mixed recording (mic + system audio)
    transcript.json     — timestamps, text, speaker labels, confidence
    metadata.json       — session info
  sessions.json         — index for the session list
```

Plain folders. Plain files. No database. Back them up however you want. Grep the JSON.

## Install

### Build from source

```bash
brew install xcodegen
git clone https://github.com/kmg/steno.git
cd steno
xcodegen generate
open Steno.xcodeproj
```

Build (Cmd+B), Run (Cmd+R).

### Homebrew (coming soon)

```bash
brew install --cask kmg/steno/steno
```

## System requirements

- **macOS 14.2+** (Sonoma). Core Audio Taps doesn't exist before 14.2.
- **Apple Silicon** (M1/M2/M3/M4). WhisperKit runs on the Neural Engine. Intel Macs don't have one.
- **~600MB disk** for the app + default model. More if you download larger models.

## Performance

During recording with live transcription:
- CPU: <10% sustained
- Neural Engine: active (0.3W)
- RAM: <2GB peak

When idle: near-zero. Model unloaded from memory.

## Privacy

No network calls after the initial model download. No analytics. No telemetry. No update checks. The app is fully air-gapped during normal use.

Your audio stays in `~/Documents/Steno/`. Delete a session folder, it's gone. There is no cloud backup, no sync, no secondary copy anywhere.

## Dependencies

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) (argmaxinc) — transcription via Core ML. MIT license.
- [FluidAudio](https://github.com/FluidInference/FluidAudio) (FluidInference) — speaker identification via Core ML. Apache 2.0.
- Apple frameworks: AVFoundation, CoreAudio, Accelerate.

## License

MIT
