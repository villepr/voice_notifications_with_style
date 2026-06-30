# API Key Help

Only the OpenAI API path is tested for the current setup.

The default notifier uses one OpenAI API key for both:

- `gpt-5.4-nano` notification rewriting.
- `gpt-4o-mini-tts` speech generation.

## Recommended Setup

Use a user environment variable:

```powershell
setx OPENAI_API_KEY "your-key-here"
```

Open a new terminal after running `setx`; existing terminals do not always pick
up new user environment variables.

For the current PowerShell session only:

```powershell
$env:OPENAI_API_KEY = "your-key-here"
```

## Local Secret File

For a local checkout, you can also create an ignored plaintext file:

```text
config\openaiapikey.secret
```

Put only the API key in that file.

This ignored JSON file is also supported:

```text
config\secrets.local.json
```

with:

```json
{
  "OPENAI_API_KEY": "your-key-here"
}
```

Do not put real API keys in `voice-notifier.config.json`, examples, traces,
commits, issues, or chat logs.

## Quick Checks

Confirm the current terminal can see the key:

```powershell
Get-ChildItem Env:OPENAI_API_KEY
```

Run an OpenAI text-only test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-VoiceNotification.ps1 -PayloadFile .\examples\completed-work.json -NoSpeak -StylingProvider openai
```

If the API base needs to be changed, add
`providers.openai.text.endpoint` or `providers.openai.speech.endpoint` to
`config\voice-notifier.config.json` to override the internal default.
