# Voice Notifier Config

Edit these files for normal use:

- `voice-notifier.config.json`: small user settings, such as default providers,
  text model, OpenAI voice, max spoken words, tracing, and Spotify ducking.
- `styling-system-prompt.txt`: the LLM rewrite prompt.
- `*.secret` or `secrets.local.json`: local API keys. These are ignored by Git.

Internal defaults live in `../src/VoiceNotifier.defaults.json`. That file keeps
provider endpoints, retry timings, fallback style profiles, keyword mappings,
and technical translations out of the normal user settings file.

Advanced overrides still work: add the same nested key path to
`voice-notifier.config.json`, and it will override the internal default.
