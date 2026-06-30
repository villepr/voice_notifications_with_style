# Voice Notifications With Style

Styled voice notifications from Codex app on Windows.

Standalone PoC for turning Codex-style notifications into spoken, music-aware
status updates.

The PoC does not modify the global Codex config. It can read a sample payload,
a payload file, stdin JSON, or a direct message. It then:

1. Extracts useful status facts.
2. Reads current media metadata from Windows media sessions.
3. Falls back to the Spotify window title when needed.
4. Builds a neutral spoken brief.
5. Rewrites it with a music-aware style profile.
6. Optionally speaks the styled brief with Windows `System.Speech`, ElevenLabs,
   or OpenAI TTS.
7. Writes a JSONL trace for later tuning.

The styled output acts like a DJ or MC when music is playing, and like an MC
when no music is detected. It summarizes technical paths and commands instead
of reading raw script names or shell commands aloud.

## Install

Requirements:

- Windows 10 or 11.
- PowerShell 5.1 or newer.
- Codex Desktop, if you want always-on Codex completion notifications.
- Spotify Desktop or any app that publishes Windows media-session metadata, if
  you want music-aware styling.
- An OpenAI API key for the default OpenAI text rewrite and OpenAI TTS path.

Clone the repository:

```powershell
git clone https://github.com/villepr/voice_notifications_with_style.git
cd voice_notifications_with_style
```

Add an API key. Preferred: use a user environment variable:

```powershell
setx OPENAI_API_KEY "your-key-here"
```

Open a new terminal after `setx`. For a local-only test checkout, you can also
create an ignored plaintext file:

```text
config\openaiapikey.secret
```

with just the key as the file contents.

Run a text-only smoke test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-VoiceNotification.ps1 -NoSpeak
```

Run a spoken test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-VoiceNotification.ps1 -Speak
```

Enable always-on Codex notifications by adding this `notify` entry to your
Codex config file, normally `%USERPROFILE%\.codex\config.toml`, with the path
adjusted to your checkout:

```toml
notify = [ "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\voice_notifications_with_style\\scripts\\Invoke-CodexNotifyVoice.ps1" ]
```

The always-on hook is detached: Codex queues the voice notification worker and
returns immediately, so slow API calls or audio playback should not block the
Codex app.

## Quick Start

From this folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-VoiceNotification.ps1 -NoSpeak
```

To hear the examples:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-VoiceNotification.ps1 -Speak
```

Run one direct message:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-VoiceNotification.ps1 -Message "Implemented the Spotify metadata fallback and the smoke tests passed." -NoSpeak
```

Run with a sample payload:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-VoiceNotification.ps1 -PayloadFile .\examples\completed-work.json -NoSpeak
```

By default this uses OpenAI for the text rewrite and OpenAI TTS for speech.
Change these under `defaults` in
`config\voice-notifier.config.json`.

Force a style while tuning text:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-VoiceNotification.ps1 -PayloadFile .\examples\completed-work.json -StyleProfile reggae -NoSpeak
```

Force OpenAI for the styling rewrite:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-VoiceNotification.ps1 -PayloadFile .\examples\completed-work.json -StylingProvider openai -NoSpeak
```

Use Gemini for the styling rewrite:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-VoiceNotification.ps1 -PayloadFile .\examples\completed-work.json -StylingProvider gemini -NoSpeak
```

Generate and save ElevenLabs audio:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-VoiceNotification.ps1 -PayloadFile .\examples\completed-work.json -TtsProvider elevenlabs -Speak
```

Generate and save OpenAI speech audio:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-VoiceNotification.ps1 -PayloadFile .\examples\completed-work.json -TtsProvider openai -Speak -SaveAudio
```

Cloud TTS playback normally uses a temp audio file and deletes it after
playback. Add `-SaveAudio` while testing to save MP3/bin output under
`output\audio` with a sidecar `.json` metadata file that records the generated
text and TTS request settings, but not the API key.

When OpenAI or Gemini returns voice tags, the OpenAI TTS adapter uses the
selected voice, voice instructions, and a clamped speed value from the style
response. Gemini free-tier availability can be uneven, so the PoC makes one
short retry and then falls back to deterministic templates instead of blocking
the notification.

Send JSON through stdin:

```powershell
Get-Content -Raw .\examples\approval-needed.json |
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-VoiceNotification.ps1 -NoSpeak
```

## Output

Each run prints:

- Current media metadata.
- Selected style profile.
- Style instructions.
- Neutral spoken brief.
- Styled spoken brief.
- TTS result.

It also appends a trace record to `output\voice-notifier.trace.jsonl`.
The always-on Codex hook writes its own small status log to
`output\codex-notify-hook.log`.

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

## Always-On Codex Hook

To enable the notifier for Codex, point the global Codex `notify` command at:

```text
scripts\Invoke-CodexNotifyVoice.ps1
```

That wrapper reads notification JSON from stdin or command-line args, normalizes
Codex `agent-turn-complete` payloads down to the final assistant message, drops
raw input-message history, writes a small queued payload under `output\pending`,
starts `Invoke-CodexNotifyWorker.ps1` in a hidden detached process, and exits
immediately. The worker then calls `Invoke-VoiceNotification.ps1 -Speak` outside
the Codex notify call. It uses a one-at-a-time lock and a runtime timeout so a
slow API call, playback issue, or overlapping notification cannot block the main
Codex process.

Failures are written to `output\codex-notify-hook.log` and swallowed so
notification problems do not break Codex turns.

Example `notify` entry, with the path adjusted to your checkout:

```toml
notify = [ "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\voice_notifications_with_style\\scripts\\Invoke-CodexNotifyVoice.ps1" ]
```

To roll back, remove the `notify` entry or restore your previous Codex config
backup.

## Desktop Session Watcher

Some Codex Desktop completion bubbles may not call the configured `notify`
command in already-running sessions. As a fallback, this PoC includes a session
watcher that follows Codex user-session JSONL files and speaks when a user-owned
turn completes. It ignores subagent session files and waits briefly to avoid
double-speaking if the native `notify` hook has already started.

Start it in the background:

```powershell
Start-Process -WindowStyle Hidden -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\path\to\voice_notifications_with_style\scripts\Start-CodexSessionVoiceWatcher.ps1")
```

Start it at every user logon with Windows Task Scheduler:

```powershell
$taskName = "Voice Notifications With Style Watcher"
$taskPath = "\Codex\"
$script = "C:\path\to\voice_notifications_with_style\scripts\Start-CodexSessionVoiceWatcher.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$script`" -StylingProvider openai -TtsProvider openai"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Starts the Codex styled voice notification session watcher at user logon." -Force
```

Stop it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Stop-CodexSessionVoiceWatcher.ps1
```

The watcher writes `output\codex-session-watcher.log` and
`output\codex-session-watcher.pid`.

## API Keys

Preferred: use user environment variables, not the project config file. The PoC
checks the environment first, then ignored local secret files.

For the current PowerShell session only:

```powershell
$env:OPENAI_API_KEY = "your-key-here"
$env:GEMINI_API_KEY = "your-key-here"
```

Persist it for future terminals:

```powershell
setx OPENAI_API_KEY "your-key-here"
setx GEMINI_API_KEY "your-key-here"
```

Open a new terminal after `setx`. Do not paste real API keys into source files,
JSON config, examples, traces, or chat logs.

For local PoC use, you can also create this ignored file:

```text
config\secrets.local.json
```

With this content:

```json
{
  "GEMINI_API_KEY": "your-key-here",
  "ELEVENLABS_API_KEY": "your-key-here",
  "OPENAI_API_KEY": "your-key-here"
}
```

`config\secrets.local.json` is ignored by this PoC's `.gitignore`. Keep the
example file, but do not put the real key in `voice-notifier.config.json`.

Plaintext one-key files are also supported and ignored:

- `config\geminiapikey.secret`
- `config\elevenlabsvoice.secret`
- `config\openaiapikey.secret`

OpenAI styling uses the same `OPENAI_API_KEY` / `config\openaiapikey.secret`
source as OpenAI TTS. If your account uses a different API base, add
`providers.openai.text.endpoint` to `config\voice-notifier.config.json` to
override the internal default.

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

## License

MIT. See `LICENSE`.

## Local Voice Lab

Local neural voice generation is being scoped separately under:

```text
experiments\local_voice_lab
```

That lab benchmarks Kokoro ONNX first, with Piper and KittenTTS as comparison
paths. It uses ignored local model/audio/output folders and does not change the
active OpenAI TTS default, the Codex notify hook, or the desktop session watcher.

## Current Limitations

- Local neural TTS is not active in the main notifier yet; it is isolated in
  `experiments\local_voice_lab` until quality and latency are proven.
- Local-only: no Spotify OAuth yet.
- Gemini styling is best-effort; free-tier rate limits or transient `503`
  responses can fall back to deterministic templates.
- Windows media session metadata can occasionally expose promotional Spotify
  cards; the Spotify process window title fallback helps with this.
- Windows `System.Speech` voices are limited; OpenAI/ElevenLabs paths are better
  for judging voice quality.

## Roadmap

See `TODO.md` for planned work on local LLM rewriting, local voice generation,
and stronger music-specific styling.
