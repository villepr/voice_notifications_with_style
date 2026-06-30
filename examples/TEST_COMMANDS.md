# Test Commands

Run these commands from the repository root.

This file documents the tested path: OpenAI text rewriting plus OpenAI TTS. The
template command is included as a local no-cloud smoke test. Paid non-OpenAI
provider paths are intentionally not documented here yet.

## Text-Only Smoke Test

No speech output, but still uses the configured text provider unless you pass
`-StylingProvider templates`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-VoiceNotification.ps1 -NoSpeak
```

## Local Template Smoke Test

No OpenAI call. Useful for checking PowerShell, payload parsing, media metadata,
and trace writing.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-VoiceNotification.ps1 -NoSpeak -StylingProvider templates
```

## Spoken Test

Uses OpenAI for text rewriting and OpenAI TTS for speech.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-VoiceNotification.ps1 -Speak
```

## Direct Message

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-VoiceNotification.ps1 -Message "Implemented the media metadata fallback and the smoke tests passed." -NoSpeak
```

## Sample Payload

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-VoiceNotification.ps1 -PayloadFile .\examples\completed-work.json -NoSpeak
```

## Force A Style While Tuning

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-VoiceNotification.ps1 -PayloadFile .\examples\completed-work.json -StyleProfile reggae -NoSpeak
```

## Save A Test Audio File

Cloud TTS playback normally uses a temporary audio file and deletes it after
playback. Add `-SaveAudio` only while testing if you want the generated OpenAI
speech file saved under `output\audio`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-VoiceNotification.ps1 -PayloadFile .\examples\completed-work.json -TtsProvider openai -Speak -SaveAudio
```

## Send JSON Through Stdin

```powershell
Get-Content -Raw .\examples\approval-needed.json |
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-VoiceNotification.ps1 -NoSpeak
```
