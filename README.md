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

The PoC uses one main config file:

```text
config\voice-notifier.config.json
```

The most common tuning points are:

- `defaults.text.provider` and `defaults.text.model` for the default rewrite
  provider/model.
- `defaults.speech.provider` for the default speech provider.
- `providers.openai.text`, `providers.gemini.text`, `providers.openai.speech`,
  `providers.elevenlabs.speech`, and `providers.windowsSpeech` for provider
  endpoints, models, timeouts, voices, and output settings.
- `prompts.styling.systemLines` for the default LLM rewrite prompt.
- `providers.openai.speech.saveAudioByDefault` and
  `providers.elevenlabs.speech.saveAudioByDefault` if you want cloud speech
  files kept without passing `-SaveAudio`.

Prompt lines support `{{maxWords}}` and `{{voiceChoices}}` placeholders. The
JSON response schema is kept in code because it is API validation behavior, not
prompt copy.

## Always-On Codex Hook

To enable the notifier for Codex, point the global Codex `notify` command at:

```text
scripts\Invoke-CodexNotifyVoice.ps1
```

That wrapper reads notification JSON from stdin when Codex provides it, falls
back to a short turn-ended message when it does not, and then calls
`Invoke-VoiceNotification.ps1 -Speak`. Failures are written to
`output\codex-notify-hook.log` and swallowed so notification problems do not
break Codex turns.

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
source as OpenAI TTS. If your account uses a different API base, edit
`providers.openai.text.endpoint` in `config\voice-notifier.config.json`.

## License

MIT. See `LICENSE`.

## Current Limitations

- Local-only: no Spotify OAuth or local neural TTS yet.
- Gemini styling is best-effort; free-tier rate limits or transient `503`
  responses can fall back to deterministic templates.
- Windows media session metadata can occasionally expose promotional Spotify
  cards; the Spotify process window title fallback helps with this.
- Windows `System.Speech` voices are limited; OpenAI/ElevenLabs paths are better
  for judging voice quality.

## Roadmap

See `TODO.md` for planned work on local LLM rewriting, local voice generation,
and stronger music-specific styling.
