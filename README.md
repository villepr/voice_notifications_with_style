# Voice Notifications With Style

Styled voice notifications from Codex app on Windows.

This is a standalone PoC for turning Codex-style notifications into spoken,
music-aware status updates. It works with or without music playing. When Windows
media metadata is available, the notifier uses it to shape the DJ/MC delivery;
when no music is detected, it falls back to a neutral MC-style update.

The currently tested path is OpenAI for both text rewriting and speech:

- `gpt-5.4-nano` rewrites the notification into a spoken update.
- `gpt-4o-mini-tts` reads it aloud.

Other provider adapters may exist in the code, but paid non-OpenAI paths are not
treated as tested or supported in this README yet.

The scripts do not modify global Codex config automatically. You opt in by
adding a `notify` command to your own Codex config.

## How It Works

For each notification, the PoC:

1. Extracts useful status facts from the Codex notification.
2. Looks for current media metadata from Windows media sessions.
3. Falls back to the Spotify window title if media metadata is unavailable.
4. Builds a plain-language brief.
5. Rewrites it into a spoken DJ/MC-style update with OpenAI.
6. Speaks it with OpenAI TTS.
7. Writes trace logs locally for tuning.

Spotify is optional. The notifier should still speak if no music app is running;
it just has less styling context.

## Install

Requirements:

- Windows 10 or 11.
- PowerShell 5.1 or newer.
- An OpenAI API key.
- Codex Desktop, if you want always-on Codex completion notifications.
- Spotify Desktop or another Windows media-session app, only if you want
  music-aware styling.

Clone the repository:

```powershell
git clone https://github.com/villepr/voice_notifications_with_style.git
cd voice_notifications_with_style
```

Set your OpenAI API key:

```powershell
setx OPENAI_API_KEY "your-key-here"
```

Open a new terminal after `setx`. More key-placement options are documented in
[API_KEY_HELP.md](API_KEY_HELP.md).

Run the example test commands from
[examples/TEST_COMMANDS.md](examples/TEST_COMMANDS.md).

To enable always-on Codex notifications, add this `notify` entry to your Codex
config file, normally `%USERPROFILE%\.codex\config.toml`, with the path adjusted
to your checkout:

```toml
notify = [ "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\voice_notifications_with_style\\scripts\\Invoke-CodexNotifyVoice.ps1" ]
```

The notify hook is detached: Codex queues the voice notification worker and
returns immediately, so slow API calls or audio playback should not block the
Codex app. To roll back, remove the `notify` entry or restore your previous
Codex config backup.

## Configuration

The user-facing config is intentionally small:

```text
config\voice-notifier.config.json
```

It is layered over internal defaults in:

```text
src\VoiceNotifier.defaults.json
```

Most users should only edit:

- `defaults.text.provider` and `defaults.text.model`
- `defaults.speech.provider`
- `prompts.styling.maxWords`
- `providers.openai.speech.voice`
- `tts.audioDucking.enabled` and `tts.audioDucking.duckVolume`
- `trace.enabled`

The main styling prompt is plain text:

```text
config\styling-system-prompt.txt
```

Provider endpoints, retry policy, built-in fallback style profiles, keyword
maps, and technical translation defaults are internal implementation defaults.
They can still be overridden by adding the same nested keys to
`config\voice-notifier.config.json`, but they are not meant to be routine user
settings.

Prompt lines support `{{maxWords}}` and `{{voiceChoices}}` placeholders. The
JSON response schema is kept in code because it is API validation behavior, not
prompt copy.

## Expected API Cost

The default setup makes two paid OpenAI API calls per spoken notification:

1. A small text rewrite with `gpt-5.4-nano`.
2. A text-to-speech request with `gpt-4o-mini-tts`.

As of June 30, 2026, OpenAI lists `gpt-5.4-nano` standard pricing at `$0.20`
per 1M input tokens and `$1.25` per 1M output tokens on the API pricing page:
https://platform.openai.com/docs/pricing

Typical notification rewrite usage is roughly 800-1,800 input tokens and
100-250 output tokens, so the text rewrite is usually about `$0.0003-$0.0007`
per notification, or about `$0.03-$0.07` per 100 notifications.

For `gpt-4o-mini-tts`, the same pricing page lists text input at `$0.60` per
1M tokens and audio output at `$12` per 1M audio tokens. The speech request is
therefore the main cost driver, and depends on the final spoken length. For the
short notifications this project generates, expect fractions of a cent to a few
cents per spoken notification, not dollars. At 100 notifications, that should
usually be well under a few dollars unless you make the spoken updates much
longer. Treat this as a budget estimate, not a billing guarantee. Check the live
OpenAI pricing page and your OpenAI usage dashboard for exact rates and usage.

To avoid speech cost while testing prompt behavior, run with `-NoSpeak`. To
avoid cloud API calls entirely for text tests, add `-StylingProvider templates`
as well.

## Local Voice Lab

Local neural voice generation is being scoped separately under:

```text
experiments\local_voice_lab
```

That lab benchmarks Kokoro ONNX first, with Piper and KittenTTS as comparison
paths. It uses ignored local model/audio/output folders and does not change the
active OpenAI TTS default or the Codex notify hook.

## Current Limitations

- The OpenAI API path is the only tested cloud path.
- Local neural TTS is not active in the main notifier yet; it is isolated in
  `experiments\local_voice_lab` until quality and latency are proven.
- Spotify is optional, but Windows media metadata can be unreliable. If no
  useful metadata is available, the notifier should still speak with neutral
  styling.
- Windows media sessions can occasionally expose promotional Spotify cards; the
  Spotify process window title fallback helps with this.

## License

MIT. See `LICENSE`.
