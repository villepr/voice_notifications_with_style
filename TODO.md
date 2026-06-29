# TODO

## Local LLM Notification Summarization And Theming

Add a local text-rewrite provider so notification summarization and music-aware
theming can run without a cloud API call. The adapter should keep the same
contract as the OpenAI/Gemini paths: input is extracted notification facts plus
now-playing metadata, output is spoken text plus voice synthesis guidance.

Key work:

- Support a configurable local provider, likely through a small HTTP-compatible
  runtime first, then lower-level runtimes if needed.
- Keep the same JSON output shape used by the current styling layer so provider
  switching does not change the rest of the notification pipeline.
- Tune prompts for smaller models: compact context, explicit constraints, and
  strong fallbacks when JSON is malformed.
- Add latency limits, retries, and cloud/template fallback behavior so a slow
  local model never blocks Codex notifications for too long.
- Compare local output against OpenAI/Gemini traces for factual preservation,
  style strength, length, and usefulness when heard aloud.
- Investigate hardware acceleration on this laptop, especially NPU-capable
  paths through ONNX Runtime, DirectML, OpenVINO, or whatever stack is practical
  for the installed processor and drivers.

## Local Voice Models For Voice Generation

Add local speech generation as a first-class speech provider, separate from the
current Windows `System.Speech`, OpenAI TTS, and ElevenLabs paths. The goal is
offline, low-friction spoken notifications with more style control than basic
Windows voices.

Key work:

- Add a `localVoice` provider block in config with model path, runtime, voice
  preset, output format, speed, and playback settings.
- Evaluate practical local TTS engines for Windows, starting with lightweight
  ONNX/Piper-style models and any current Windows-native neural voice options.
- Test whether NPU acceleration is actually available for the selected runtime;
  fall back to CPU/GPU if setup cost or driver support makes NPU impractical.
- Preserve the current audio behavior: duck Spotify during playback, use temp
  files by default, save audio only when requested, and log metadata without
  writing secrets.
- Decide how voice instructions from the styling layer map onto local model
  controls such as speaker, speed, pitch, temperature, emotion, or style tokens.
- Measure end-to-end latency. The target should feel like a notification, not a
  delayed narration after the moment has passed.

## Stronger Thematic Adherence To Music Style, Band, And Lead Voice

Make the styling layer more musically specific and more willing to take a
creative stance. The notifier should feel like a DJ or MC speaking over the
actual track, not a generic genre preset.

Key work:

- Use richer music context when available: artist, title, album, playback
  status, likely genre, era, language, country/region, tempo, energy, mood,
  production feel, and whether the track is instrumental or vocal-led.
- When a track has a clear lead vocal, infer delivery cues from that performance:
  pacing, warmth, intensity, breathiness, texture, phrasing, accent/language
  feel, and how hard the words should be pushed.
- Move beyond broad labels like `cinematic`; allow the style decision to choose
  a narrator archetype that fits the track, such as nightclub DJ, radio host,
  stage MC, secret-agent briefing, villain monologue, deadpan announcer, dance
  caller, or late-night indie presenter.
- Keep the output useful as a Codex status update. Style can be heavy, but it
  should not bury the actual notification facts.
- Avoid generic catchphrases and costume-like parody. The music should guide
  atmosphere, rhythm, vocabulary, and vocal energy.
- Add trace fields for the model's inferred style rationale so bad style choices
  can be tuned without guessing.
- Consider optional metadata enrichment later, such as cached artist/track notes
  or user-defined overrides, while keeping the default path fast and local-first.
