# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**sciFM** (formerly Glados/PaperAudio) is an iOS app that converts academic papers into audio using Deepgram or OpenAI TTS. Users share a paper URL (PubMed, PMC, etc.) and the app fetches the article, optionally cleans it with an LLM, and streams it as speech. The app also has a Discover feed (Nature/Science/Cell RSS) and a Papers search tab (Europe PMC).

## Build & Test

This is a pure Swift/Xcode project — no package manager or Makefile.

```bash
# Build
xcodebuild -scheme sciFM -configuration Debug

# Run all tests
xcodebuild -scheme sciFM test

# Run a single test class
xcodebuild -scheme sciFM test -only-testing sciFMTests/ArticleProcessorTests

# Run a single test method
xcodebuild -scheme sciFM test -only-testing sciFMTests/ArticleProcessorTests/testCitationStripping
```

The project is configured via `project.yml` (XcodeGen). If `.xcodeproj` is regenerated, run `xcodegen generate` from the repo root.

- Deployment target: iOS 17.0
- Swift 5.9

## Architecture

**MVVM with Swift actors and async/await throughout.**

### Key Components

| File | Role |
|------|------|
| `PaperAudioApp.swift` | App entry point; deep link handling (`scifm://open?url=`); checks App Group for URLs from share extension |
| `PlayerView.swift` | SwiftUI view + `PlayerViewModel` (orchestrates the full pipeline); root tab bar host |
| `ArticleProcessor.swift` | Actor; DOI extraction → article fetching → text cleaning |
| `DeepgramTTS.swift` | Actor; streams PCM audio from Deepgram; also contains `TextChunker` and `WAVBuilder` |
| `OpenAITTS.swift` | Actor; streams PCM audio from OpenAI (`tts-1`); same format as Deepgram |
| `AudioStreamPlayer.swift` | `@MainActor`; AVAudioEngine-based streaming playback; Now Playing / remote controls |
| `AbstractPlayer.swift` | `@MainActor`; lightweight AVAudioPlayer-based TTS for short texts (abstracts in feed/search) |
| `LLMCleaner.swift` | Actor; optional LLM post-processing of article text and figure narrations (Anthropic or OpenAI) |
| `ScientificPronunciation.swift` | Pure functions; rewrites scientific abbreviations for TTS (e.g. `IL-6` → `interleukin 6`, `mRNA` → `M R N Ay`) |
| `LibraryManager.swift` / `Library.swift` | Actor; persists played articles as WAV files + metadata in `Documents/` |
| `AppSettings.swift` | `UserDefaults`-backed enum for TTS provider (Deepgram/OpenAI) and LLM provider (none/haiku/sonnet/opus/gpt4o-mini) |
| `FigureModels.swift` | Value types for figure panels and timestamps (`FigurePanel`, `PanelTimestamp`, `ProcessedFigures`) |
| `FigurePlayerView.swift` | Figure-centric playback UI; shows synchronized panel images and legends |
| `DiscoverFeed.swift` | `FeedManager` actor; fetches RSS from Nature/Science/Cell; Europe PMC search; thumbnail/abstract fetching |
| `DiscoverView.swift` | Discover tab UI; article feed, abstract audio buttons, full-article navigation |
| `PapersView.swift` | Papers tab UI; Europe PMC search by keyword/author/DOI; pastes URLs directly into player |
| `LibraryView.swift` | Library tab UI; lists saved articles with resume-from-position |
| `WebReaderView.swift` | In-app web browser for viewing paper source pages |
| `Keychain.swift` | Security framework wrapper for API keys; `APIKeySetupView` |
| `ShareExtension/ShareViewController.swift` | App extension; writes URL to shared App Group UserDefaults |

### Data Flow

```
User shares URL / pastes URL / taps from feed
  → PlayerViewModel.load(url:) or .readText(_:title:)
  → ArticleProcessor.process(url)
      - DOI extraction: regex → PMID/PMC NCBI lookup → HTML scrape fallback
      - Article fetch: PMC XML (NCBI e-utils) → Unpaywall OA → PDF/HTML fallback
      - Text cleaning: strip citations, figures, references section
  → (optional) LLMCleaner.clean(title:text:)  ← controlled by AppSettings.llmProvider
  → ScientificPronunciation.rewrite(text)      ← always applied
  → TextChunker splits text into ~500-char sentence-boundary chunks
  → DeepgramTTS.stream(chunk) or OpenAITTS.stream(chunk)  ← AppSettings.ttsProvider
       → AsyncThrowingStream<Data> of raw PCM chunks
  → AudioStreamPlayer schedules PCM buffers on AVAudioEngine
  → (on completion) LibraryManager.save() persists WAV + metadata
```

**Figure mode** (separate pipeline): when a paper has extractable figures, `PlayerViewModel` populates `panels: [FigurePanel]` and `FigurePlayerView` shows images/legends synchronized to narration via `PanelTimestamp`.

**Abstract audio** (in feed/search): `AbstractPlayer.shared` handles lightweight TTS for short texts; it collects all PCM chunks into a single in-memory WAV and plays it via `AVAudioPlayer`, independently of the main `PlayerViewModel`.

### Concurrency Model

- `ArticleProcessor`, `DeepgramTTS`, `OpenAITTS`, `LLMCleaner`, `LibraryManager`, `FeedManager` are Swift actors.
- `AudioStreamPlayer`, `PlayerViewModel`, `AbstractPlayer` are `@MainActor`.
- All networking uses `URLSession` with `async/await`.

### Audio Pipeline Detail

- Both Deepgram and OpenAI TTS return linear16 PCM at 24 kHz mono.
- `AudioStreamPlayer` converts int16 → float32 before scheduling AVAudioPlayerNode buffers.
- Playback starts after 2+ buffers are scheduled to avoid underruns.
- `WAVBuilder.make(pcmData:)` (in `DeepgramTTS.swift`) wraps raw PCM with a WAV header for persistence and `AbstractPlayer`.

### Text Cleaning

`ArticleProcessor` aggressively removes citations and academic boilerplate. The cleaner preserves scientific terms (gene names like IL6, p53, H3K27me3) via an English-word allowlist — be careful when modifying the cleaning regex patterns.

`ScientificPronunciation.rewrite()` is applied to all text (including abstracts) before TTS. Add new substitutions there for acronyms that TTS mispronounces.

### External APIs

| API | URL | Auth |
|-----|-----|------|
| NCBI E-utilities | `eutils.ncbi.nlm.nih.gov` | None |
| Europe PMC | `ebi.ac.uk/europepmc` | None |
| Unpaywall | `api.unpaywall.org` | None |
| Deepgram TTS | `api.deepgram.com/v1/speak` | Keychain key `deepgramAPIKey` |
| OpenAI TTS + LLM | `api.openai.com` | Keychain key `openaiAPIKey` |
| Anthropic LLM | `api.anthropic.com` | Keychain key `anthropicAPIKey` |

### Share Extension Communication

The share extension runs in a separate process and cannot call back into the main app directly. It writes the URL to a shared `UserDefaults` suite (App Group). The main app reads and clears this value each time it enters the foreground.
