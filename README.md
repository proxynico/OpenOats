# OpenOats

A meeting note-taker that talks back.

OpenOats sits next to your call, transcribes both sides of the conversation in real time, and searches your own notes to surface things worth saying — right when you need them.

> Our fork of [yazinsai/OpenOats](https://github.com/yazinsai/OpenOats) (MIT). We develop and customize it for our own use. Upstream is wired as the `upstream` git remote.

<p align="center">
  <img src="assets/hero.svg" width="720" alt="OpenOats during a call — suggestions drawn from your own notes appear at the top, live transcript below" />
</p>

## Features

- **Invisible to the other side** — the app window is hidden from screen sharing by default, so no one knows you're using it
- **Fully offline transcription** — speech recognition runs entirely on your Mac; no audio ever leaves the device
- **Runs 100% locally** — pair with [Ollama](https://ollama.com/) for LLM suggestions and local embeddings, and nothing touches the network at all
- **Pick any LLM** — use [OpenRouter](https://openrouter.ai/) for cloud models (GPT-4o, Claude, Gemini) or Ollama for local ones (Llama, Qwen, Mistral)
- **Live transcript** — see both sides of the conversation as it happens, copy the whole thing with one click
- **Auto-saved sessions** — every conversation is automatically saved as a plain-text transcript and a structured session log, no manual export needed
- **Knowledge base search** — point it at a folder of notes and it pulls in what's relevant using [Voyage AI](https://www.voyageai.com/) embeddings, local Ollama embeddings, or any OpenAI-compatible endpoint (llama.cpp, llamaswap, LiteLLM, vLLM, etc.)

## How it works

1. You start a call and hit **Live**
2. OpenOats transcribes both speakers locally on your Mac
3. When the conversation hits a moment that matters — a question, a decision point, a claim worth backing up — it searches your notes and surfaces relevant talking points
4. You sound prepared because you are

## Recording Consent & Legal Disclaimer

**Important:** OpenOats records and transcribes audio from your microphone and system audio. Many jurisdictions have laws requiring consent from some or all participants before a conversation may be recorded (e.g., two-party/all-party consent states in the U.S., GDPR in the EU).

**By using this software, you acknowledge and agree that:**

- **You are solely responsible** for determining whether recording is lawful in your jurisdiction and for obtaining any required consent from all participants before starting a session.
- **The developers and contributors of OpenOats provide no legal advice** and make no representations about the legality of recording in any jurisdiction.
- **The developers accept no liability** for any unauthorized or unlawful recording conducted using this software.

**Do not use this software to record conversations without proper consent where required by law.**

The app will ask you to acknowledge these obligations before your first recording session.

## Build from source

```bash
# Full build → sign → install to /Applications
./scripts/build_swift_app.sh

# Dev build only
cd OpenOats && swift build -c debug
```

Optional env vars for code signing and notarization: `CODESIGN_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`.

## Quick start

1. Build and launch the app, then grant microphone + system audio recording permissions
2. Open Settings (`Cmd+,`) and pick your providers:
   - **Cloud**: add your OpenRouter and Voyage AI API keys
   - **Local**: select Ollama as your LLM and embedding provider (make sure Ollama is running)
   - **OpenAI-compatible**: select "OpenAI Compatible" as your embedding provider and point it at any `/v1/embeddings` endpoint
3. Point it at a folder of `.md` or `.txt` files — that's your knowledge base
4. Click **Idle** to go live

The first run downloads the local speech model (~600 MB).

## What you need

- Apple Silicon Mac, macOS 15+
- Xcode 26 / Swift 6.2
- **For cloud mode**: [OpenRouter](https://openrouter.ai/) API key + [Voyage AI](https://www.voyageai.com/) API key
- **For local mode**: [Ollama](https://ollama.com/) running locally with your preferred models (e.g. `qwen3:8b` for suggestions, `nomic-embed-text` for embeddings)
- **For OpenAI-compatible embeddings**: any server implementing `/v1/embeddings` (llama.cpp, llamaswap, LiteLLM, vLLM, etc.)

## Knowledge base

Point the app at a folder of Markdown or plain text files. That's it. OpenOats chunks, embeds, and caches them locally. When the conversation shifts, it searches your notes and only surfaces what's actually relevant.

Works well with meeting prep docs, research notes, pitch decks, competitive analysis, customer briefs — anything you'd want at your fingertips during a call.

## Privacy

- Speech is transcribed locally — audio never leaves your Mac
- **With Ollama**: everything stays on your machine. Zero network calls.
- **With cloud providers**: KB chunks are sent to Voyage AI (or your chosen OpenAI-compatible endpoint) for embedding (text only, no audio), and conversation context is sent to OpenRouter for suggestions
- API keys are stored in your Mac's Keychain
- The app window is hidden from screen sharing by default
- Transcripts are saved locally to `~/Documents/OpenOats/`

### Cloud mode: what data leaves your Mac

When using cloud providers, OpenOats makes the following network requests. **No audio is ever sent** — only text. In fully-local mode (Ollama for both LLM and embeddings), nothing touches the network at all.

| Step | When | Provider | What is sent |
|---|---|---|---|
| KB indexing | Each time the KB folder is indexed (launch or file change) | Voyage AI `…/v1/embeddings` | Text chunks from your `.md`/`.txt` files (80–500 words, with header breadcrumb), model + dimensions, input type `document`. Batches of 32; only new/changed files. |
| KB search | Each suggestion run (substantive utterance, 90s cooldown) | Voyage AI `…/v1/embeddings` | 1–4 short query strings derived from the conversation; model, dimensions, input type `query`. |
| KB reranking | After search, if Voyage is the embedding provider | Voyage AI `…/v1/rerank` | The primary query + up to 10 candidate KB chunks; model name. |
| Conversation state | Periodically during a session | OpenRouter `…/chat/completions` | Previous state, recent transcript utterances (text only), latest other-speaker utterance, system prompt. |
| Surfacing gate | After KB search returns results | OpenRouter `…/chat/completions` | Latest utterance, recent exchange, conversation state, trigger excerpt, up to 5 KB chunks, recently shown angles. |
| Suggestion generation | If the gate approves | OpenRouter `…/chat/completions` | Latest utterance, conversation state, gate reasoning, up to 3 KB chunks. |
| Notes generation | When you click "Generate Notes" | OpenRouter `…/chat/completions` | Full transcript (text + timestamps, truncated to ~60k chars), the template's system prompt. |

**Never sent:** audio (transcription is always on-device via Apple Speech), system file paths/filenames (only KB source filenames), or your API keys to anyone other than the respective provider. With Ollama, nothing leaves the machine.

## Repo layout

```
OpenOats/             SwiftUI app (Swift Package)
scripts/              Build, sign, and install scripts
assets/               Screenshot and app icon source
docs/                 Project docs
```

## License

MIT — see [LICENSE](LICENSE). Original work © yazinsai and OpenOats contributors.
