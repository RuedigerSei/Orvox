# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this app does

Orvox is a macOS app (Swift 6 / SwiftUI) that converts documents (PDF, RTF, TXT) into M4B audiobooks with chapter markers using a local Qwen3-TTS model running on Apple Silicon via MLX.

## Build & run

The project uses **XcodeGen** — `project.pbxproj` is generated, never hand-edited.

```bash
# Regenerate Xcode project after changing project.yml
xcodegen generate

# Set up the Python venv (first time only)
python3.11 -m venv tts_venv
tts_venv/bin/pip install mlx-audio fastapi "uvicorn[standard]" soundfile numpy librosa

# Run the TTS server manually (useful for testing server.py changes)
TTS_PORT=11435 tts_venv/bin/python Orvox/Resources/tts_server/server.py
```

Open `Orvox.xcodeproj` in Xcode and build/run normally. There are no unit tests.

### Required Xcode scheme environment variables

The scheme (in `project.yml`) sets these — they must be present for the app to find the venv:

| Key | Value |
|---|---|
| `TTS_PORT` | `11435` |
| `TTS_VENV_PATH` | `/Users/ruediger/Documents/Xcode Projects/Orvox/tts_venv` |

If `TTS_VENV_PATH` is not set, the app falls back to the bundle-adjacent `tts_venv/` then `/usr/bin/python3`, both of which lack `mlx-audio`.

### HuggingFace model cache

Models download automatically on first synthesis to `~/.cache/huggingface/hub/`. The only models in use are:
- `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit` (~3.5 GB)
- `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit` (~1.2 GB)

## Architecture

### Full pipeline (one job)

```
Drop file → TextExtractor → ChunkSplitter → PipelineCoordinator
                                                    ↓  (parallel Swift tasks)
                                               TTSClient → HTTP POST /synthesize
                                                                    ↓
                                               server.py (FastAPI + MLX)
                                                                    ↓
                                               WAV bytes returned per chunk
                                                    ↓
                                               M4AWriter (AVFoundation)
                                                    ↓
                                               .m4b file with chapter track
```

### Swift side

- **`PipelineCoordinator`** (actor) — orchestrates one job at a time. Drives a `withThrowingTaskGroup` that sends chunks concurrently to the TTS server (concurrency capped by `UserDefaults "concurrentChunks"`). Contains a health watchdog that polls every 20 s and cancels the job after 3 misses (~60 s vs the 15-min URLSession timeout). Retries once on `URLError.cancelled` (-999), which occurs on cold start due to IPv4/IPv6 racing.

- **`ChunkSplitter`** — splits extracted text into `TextChunk` objects (max 400 words) using `NLTokenizer`. Chapter headings (`Chapter N`, `CHAPTER N`, `Part N`, `N.`) always force a chunk boundary and carry a `chapterTitle` for the chapter track. Decorative separators (lines with no letters) are dropped.

- **`TTSClient`** (actor) — HTTP client with 15-min per-request / 2-h per-resource timeouts. Always uses `127.0.0.1` (never `localhost`) to avoid IPv6 connection races.

- **`M4AWriter`** — concatenates WAV chunks into a single temp WAV, encodes to HE-AAC M4A via `AVAssetWriter`, then injects a QuickTime chapter track (`chap` + `tref`) by patching the raw MP4 atoms. Chapter timestamps come from accumulating real WAV durations across chunks (not estimated).

- **`PythonServerManager`** — launches/adopts/restarts the Python server process. Key behaviours:
  - Adopts a healthy existing server on port 11435 (avoids double-launch).
  - Kills orphaned processes with `lsof -ti:11435 | xargs kill -9` before launching.
  - Does not restart if the server dies within 10 s of launch (bind error / missing dep).
  - `waitForHealth()` runs as a fire-and-forget background Task (up to 900 s) so `start()` returns immediately.

- **`VoiceProfileStore`** — persists cloned voice profiles as JSON in `UserDefaults "voice_profiles_v1"`. Audio samples are stored in `~/Library/Application Support/Orvox/Voices/`. `defaultVoiceProfileID` (UserDefaults) controls which profile is pre-selected in the voice picker on launch.

- **`JobStore`** — persists jobs across launches in `UserDefaults "jobs_v1"`.

### Python server (`Orvox/Resources/tts_server/server.py`)

FastAPI app with three endpoints: `GET /health`, `POST /config`, `POST /synthesize`.

**Critical constraint — MLX thread affinity:** MLX Metal streams are thread-local. The model must be loaded and used on the **same thread**. This is enforced with a `ThreadPoolExecutor(max_workers=1)`: both model loading (at startup via `lifespan`) and every inference call are dispatched through this single executor via `loop.run_in_executor`. Never move MLX operations off this executor.

**mlx-audio API:**
```python
from mlx_audio.tts import load
model = load("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit")
# model.generate() is a generator that yields audio chunks
audio = b"".join(model.generate(text, ref_audio=path, ref_text=None, instruct=instruct_str))
```
The `instruct` parameter is an optional string that steers the narration style (tone, pace, etc.). It is resolved entirely on the Swift side (`NarrationStyle.resolvedInstruct`) and sent as the full prompt text; the server passes it through unchanged. If `None`, the model uses its default speaking style.

Synthesis always uses the base model with `ref_audio` voice cloning. If `reference_audio_path` is null, falls back to the bundled `default_voice.wav`.

**`SynthBody` schema:**
```python
class SynthBody(BaseModel):
    text: str
    reference_audio_path: Optional[str] = None
    preset: str = "audiobook"
    instruct: Optional[str] = None
```

The server is **not bundled inside the .app**; it lives next to the app at the path resolved by `serverScriptURL()` and is launched as a subprocess by `PythonServerManager`.

### Narration styles (`NarrationStyle.swift`)

Five presets: `audiobook`, `audiobookDramatic`, `science`, `broadcast`, `preview`. Each has a hardcoded `defaultInstruct` prompt. Users can override per-style in Settings; overrides are stored in UserDefaults under key `"narrationPrompt_\(rawValue)"`. The resolved text (`resolvedInstruct`) is sent as the `instruct` field to the server.

- Prompts are resolved 100% in Swift. The server has no knowledge of style names.
- New styles require only a new `case` in the enum and a `defaultInstruct` string — no server changes.

### Chapter markers

Chapter markers are injected as a native QuickTime chapter track (text track with `tref/chap` reference) directly into the M4B file atoms by `M4AWriter.injectChapterTrack`. Timestamps come from accumulating real WAV durations across chunks in `PipelineCoordinator` — not estimated.

**Known offset problem (unresolved):** All chapter markers land ~5 s too early. Root cause: the chapter track timeline starts at t=0, but the first chapter heading (e.g. "Chapter 1.") appears after a title/author preamble chunk whose audio occupies the first few seconds. The chapter track's first sample therefore maps to movie time 0 instead of the actual start of "Chapter 1."

**Approaches tried and abandoned:**

| Approach | Outcome |
|---|---|
| **Pre-roll empty sample** — prepend a zero-length text sample of duration = preamble length to the chapter track | Fixes the offset but causes off-by-one: the empty sample is counted as "Chapter 1" by audiobook players, shifting all real chapters up by one. |
| **Void edit list entry** — use a 2-entry elst with `media_time = 0xFFFFFFFF` (-1) for the preamble gap | Theoretically correct per MP4 spec; reverted together with the standalone-chunk change before it could be tested independently. |
| **Standalone chapter-title chunks** — emit each chapter heading as its own 1-sentence TTS chunk so it synthesises separately (natural trailing silence = pause before body text) | Reverted: adds one extra TTS HTTP round-trip per chapter heading, dramatically increasing processing time for books with many chapters. |

### Concurrency model

- Swift actors (`PipelineCoordinator`, `TTSClient`, `JobStore`) handle Swift-side thread safety.
- The Python server serialises all MLX work through its single-threaded executor.
- Multiple Swift chunks can be in-flight simultaneously; the server queues them.
- **Two-worker parallelism benchmarked (M4):** Sequential 29.3 s vs parallel 24.3 s = 1.21× speedup. Each inference takes ~65% longer when two run in parallel due to unified-memory bandwidth contention. Not worth implementing.
- **Embedding pre-cache:** Voice clone embedding computation costs ~200–500 ms per synthesis call. For a 64-chunk book that is ~13–32 s total — negligible compared to inference time. Not implemented.
- **Larger chunks:** Max chunk size is 400 words. Combining short chapters up to 400 words would reduce chunk count but was rejected because precise chapter markers are mandatory — a chapter boundary must always force a chunk split.

## Key UserDefaults keys

| Key | Type | Purpose |
|---|---|---|
| `serverURL` | String | TTS server base URL (default `http://127.0.0.1:11435`) |
| `modelSize` | String | `"1.7b"` or `"0.6b"` |
| `concurrentChunks` | Int | Parallel synthesis tasks (default 2) |
| `defaultPreset` | String | `"audiobook"` or `"podcast"` |
| `outputFolder` | String | Output directory path (default `~/Documents/Orvox/`) |
| `defaultVoiceProfileID` | String | UUID string of the default voice profile |
| `defaultNarrationStyle` | String | Raw value of the default `NarrationStyle` (empty = none) |
| `narrationPrompt_audiobook` | String | User-edited instruct prompt for the Audiobook style |
| `narrationPrompt_audiobookDramatic` | String | User-edited instruct prompt for Dramatic style |
| `narrationPrompt_science` | String | User-edited instruct prompt for Science style |
| `narrationPrompt_broadcast` | String | User-edited instruct prompt for Broadcast style |
| `narrationPrompt_preview` | String | User-edited instruct prompt for Preview style |
| `voice_profiles_v1` | Data | JSON-encoded `[VoiceProfile]` |
| `jobs_v1` | Data | JSON-encoded `[Job]` |

Narration prompt keys follow the pattern `"narrationPrompt_\(NarrationStyle.rawValue)"`. The key is absent when the user has not customised the style (falls back to the hardcoded default).

## Do not use PyTorch

**PyTorch CPU inference is unacceptably slow for real-time TTS on Apple Silicon.** MLX uses the GPU/ANE via Metal and is orders of magnitude faster. The entire synthesis stack is MLX-only. Do not introduce PyTorch as an alternative or fallback for any part of the TTS pipeline.
