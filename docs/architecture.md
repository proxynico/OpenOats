# OpenOats Architecture

A map of how the app fits together, for fast orientation. All paths are under `OpenOats/Sources/OpenOats/` unless noted.

## Data flow

```
 mic ─┐                              ┌─ partial text (live UI)
      ├─► Audio ──► Transcription ──►│
 sys ─┘  (capture)  (VAD+ASR+diariz) └─ final Utterance ─► TranscriptStore
                                                              │  (utterances + ConversationState)
                                                              ▼
                                                       SuggestionEngine  ◄── KnowledgeBase (your notes)
                                                       (gate → throttle → stream)
                                                              │
                                                              ▼
                                                      live suggestions (UI)

  on "Stop":  TranscriptStore ─► SessionRepository (flat files) ─► NotesEngine ─► notes.md

  Backbone:  AppCoordinator (state machine: idle│recording│ending)
             + LiveSessionController (side effects + 250ms poll loop)
```

## Stages

### 1. Audio capture — `Audio/`
The two sides are captured by different OS APIs and kept as separate streams end to end.
- `MicCapture.swift` — your voice via **AVAudioEngine** input tap (+ optional AEC). `bufferStream(deviceID:echoCancellation:)`.
- `SystemAudioCapture.swift` — the other side via **Core Audio process taps (CATap) + aggregate device** (macOS 13+), mixed to mono. Tap flags at `SystemAudioCapture.swift:71-75`.
- `AudioRecorder.swift` — writes both to CAF, merges to 48kHz M4A on finalize (kept ~7 days for re-transcription).

### 2. Transcription — `Transcription/`
Pluggable speech engines behind one protocol.
- `TranscriptionEngine.swift` — orchestrates two `StreamingTranscriber` instances (one per stream).
- `StreamingTranscriber.swift` — Silero **VAD** loop → flush segments → partial/final text.
- `TranscriptionBackend.swift` protocol; backends: **Parakeet** & **Qwen3** (FluidAudio, local), **WhisperKit** (local CoreML), **AssemblyAI** & **ElevenLabs** (cloud). Selected by `settings.transcriptionModel` → `TranscriptionModel.makeBackend()` in `Settings/SettingsTypes.swift`.
- `DiarizationManager.swift` — optional multi-speaker labeling on the system stream. Default labeling is source-based: mic = `.you`, system = `.them` (`TranscriptionEngine.swift:927/1052`).
- Output: `Utterance` (`Domain/Utterance.swift`) appended to `Models/TranscriptStore.swift`.

### 3. Intelligence / "talks back" — `Intelligence/`
The headline feature: a 3-layer pipeline, mostly local heuristics with two LLM touchpoints (state update + synthesis).
- `SuggestionEngine.swift` — orchestrator. Per utterance: dedup → maybe update `ConversationState` (LLM) → KB search → `RealtimeGate` (local heuristic, no LLM) → `BurstDecayThrottle` (pacing) → stream synthesis (LLM, ~200 tokens).
- `RealtimeGate.swift` — local surfacing heuristic; trigger classification (question/claim/topic) at `RealtimeGate.swift:68-97`.
- `BurstDecayThrottle.swift` — pacing (surface/replace/drop).
- `KnowledgeBase.swift` — loads `.md`/`.txt`, markdown-chunks (80–500 words + header breadcrumb at `KnowledgeBase.swift:588`), embeds, caches to `~/Library/Application Support/OpenOats/kb_cache.json`, cosine search + optional Voyage rerank.
- Provider clients: `OpenRouterClient.swift` (LLM: OpenRouter/OpenAI/Anthropic/Ollama/MLX/OpenAI-compatible), `VoyageClient.swift` + `OllamaEmbedClient.swift` (embeddings). Active provider chosen from settings in `SuggestionEngine.swift:502-541` / `KnowledgeBase.swift:693-715`.
- `SidecastEngine.swift` — alternate multi-persona mode.

### 4. Notes — `Intelligence/NotesEngine.swift` + `Storage/TemplateStore.swift`
- "Generate Notes" assembles the full transcript (`[HH:MM:SS] Speaker: text`, truncated ~60k chars) + a template system prompt → streams via the LLM clients.
- 6 built-in templates (Generic, 1:1, Customer Discovery, Hiring, Stand-Up, Weekly) in `TemplateStore.swift:38`; users can add custom ones. Persisted to `templates.json`.

### 5. Storage — `Storage/SessionRepository.swift`
Flat files, no database. Per session under `~/Library/Application Support/OpenOats/sessions/<id>/`: `session.json`, `transcript.live.jsonl` / `transcript.final.jsonl`, `notes.md` + `notes.meta.json`, `scratchpad.md`, `audio/`, `attachments/`. Optional human-readable mirror to `~/Documents/OpenOats/`.

### 6. Orchestration backbone — `App/`
- `Domain/MeetingState.swift` — pure state machine: `idle → recording → ending → idle`, driven by `MeetingEvent`s.
- `AppCoordinator.swift` — owns the state machine; on each transition calls into the session controller.
- `LiveSessionController.swift` (~1.6k LOC — the workhorse) — start/finalize session, the 250ms poll loop, settings-change reactions, auto-notes, batch re-transcription. Most lifecycle-spanning features hook in here.
- `AppContainer.swift` — DI bootstrap. `MeetingDetectionController.swift` auto-detects calls (camera/mic/app).

## Where to change X

| Goal | Location |
|---|---|
| Tune suggestion prompts (state / synthesis) | `Intelligence/SuggestionEngine.swift:545-697` |
| Fire more/less often | `Settings/SettingsTypes.swift:94-138` (verbosity: quiet 90s / balanced 45s / eager 15s) + `Intelligence/BurstDecayThrottle.swift` |
| Change what triggers a suggestion | `Intelligence/RealtimeGate.swift:68-97` |
| Tune KB relevance / chunking | `kbSimilarityThreshold` in settings; chunk sizes `Intelligence/KnowledgeBase.swift:588` |
| Add/swap an LLM or embedding provider | enum in `Settings/SettingsTypes.swift` → selection in `SuggestionEngine.swift:502-541` / `KnowledgeBase.swift:693-715` → client class |
| Edit note templates | `Storage/TemplateStore.swift:38-177` |
| Swap/tune transcription engine or speaker labels | new `TranscriptionBackend` + `SettingsTypes` factory; labels `TranscriptionEngine.swift:927/1052` |
| Change capture (device, stereo, gain) | `Audio/MicCapture.setInputDevice`, `Audio/SystemAudioCapture.swift:71-75` |
| Hook a lifecycle-spanning feature | `App/LiveSessionController.swift` — `startTranscription()` (~590), `finalizeCurrentSession()` (~681), poll loop (~1447) |

## Notes
- Local-first: Parakeet/Qwen3/Whisper run on-device; gate/throttle/dedup are local heuristics. LLMs are only hit for state-update, synthesis, and notes — tuning is mostly prompts + thresholds, not new infra.
- `LiveSessionController` is the gravity well for session-lifecycle work; `SuggestionEngine` for the copilot behavior.

## Build

```bash
./scripts/build_swift_app.sh          # release build → bundle → sign → install to /Applications
cd OpenOats && swift build -c debug   # dev build only
```
