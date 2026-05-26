"""
Orvox TTS server — FastAPI wrapper around Qwen3-TTS.

Backend is selected at startup via TTS_BACKEND env var:
  pytorch (default) — Qwen3-TTS via HuggingFace + PyTorch, CPU, pool of workers
  mlx               — Qwen3-TTS via mlx-audio, Apple Silicon GPU/ANE, single worker

Endpoints
---------
GET  /health      → {status, model_size, device, backend, workers, cv_ready}
POST /config      → {"model_size": "0.6b"} switches models in place
POST /synthesize  → WAV bytes (audio/wav)
                    body: {
                        "text": str,
                        "speaker": str | null,         built-in voice name, e.g. "Ryan"
                        "reference_audio_path": str | null,
                        "preset": "audiobook" | "podcast",
                        "language": str | null         (defaults to "English")
                    }
                    Priority: speaker > reference_audio_path > bundled default_voice.wav
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import io
import logging
import os
import queue
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Optional

import numpy as np
import soundfile as sf
import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")
log = logging.getLogger("orvox-tts")

# ── Config ───────────────────────────────────────────────────────────────────

PORT      = int(os.environ.get("TTS_PORT",    "11435"))
BACKEND   = os.environ.get("TTS_BACKEND", "pytorch").lower()   # "mlx" | "pytorch"
POOL_SIZE = 1 if BACKEND == "mlx" else int(os.environ.get("TTS_WORKERS", "2"))

# PyTorch model IDs
MODEL_IDS: dict[str, str] = {
    "1.7b": "Qwen/Qwen3-TTS-12Hz-1.7B-Base",
    "0.6b": "Qwen/Qwen3-TTS-12Hz-0.6B-Base",
}
CV_MODEL_IDS: dict[str, str] = {
    "1.7b": "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
    "0.6b": "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice",
}

# MLX model IDs (mlx-community 8-bit quantized)
MLX_IDS: dict[tuple[str, str], str] = {
    ("base",   "1.7b"): "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit",
    ("base",   "0.6b"): "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
    ("custom", "1.7b"): "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
    ("custom", "0.6b"): "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
}

DEFAULT_SIZE = "1.7b"

SERVER_DIR        = Path(__file__).resolve().parent
DEFAULT_REF_AUDIO = SERVER_DIR / "default_voice.wav"
DEFAULT_REF_TEXT  = (
    "Okay. Yeah. I resent you. I love you. I respect you. But you know what? "
    "You blew it! And thanks to you."
)

# ── PyTorch state ─────────────────────────────────────────────────────────────

_pool: queue.Queue = queue.Queue()
_model_size: Optional[str]          = None
_device: str                        = "cpu"
_dtype: torch.dtype                 = torch.float32
_load_error: Optional[str]          = None

_cv_lock:       threading.Lock = threading.Lock()
_cv_model:      Optional[Any]  = None
_cv_model_size: Optional[str]  = None
_cv_load_error: Optional[str]  = None

# ── MLX state ─────────────────────────────────────────────────────────────────

# Single-threaded executor: MLX Metal streams are thread-local, so every MLX
# operation (load + inference) must run on the same thread.
_mlx_executor    = concurrent.futures.ThreadPoolExecutor(max_workers=1)
_mlx_base_obj:   Optional[Any] = None   # base model for voice cloning
_mlx_cv_obj:     Optional[Any] = None   # CustomVoice model for built-in speakers
_mlx_model_size: Optional[str] = None
_mlx_load_error: Optional[str] = None


def _init_mlx_imports() -> bool:
    try:
        import mlx_audio.tts  # noqa: PLC0415
        return True
    except ImportError as e:
        log.error("mlx-audio not available: %s", e)
        return False


# ── Shared helpers ────────────────────────────────────────────────────────────

def _pick_device() -> tuple[str, torch.dtype]:
    # MPS disabled: PyTorch's structured_add_out_mps kernel triggers a Metal
    # validation abort (dispatchThreads:threadsPerThreadgroup: with invalid
    # compute function arguments) during qwen-tts inference on macOS 26.4 /
    # M-series. CPU is stable; revisit when PyTorch fixes the MPS kernel.
    if torch.cuda.is_available():
        return "cuda:0", torch.bfloat16
    return "cpu", torch.float32


def _wav_response(waveform: np.ndarray, sr: int, target_sr: int) -> Response:
    if sr != target_sr:
        try:
            import librosa  # noqa: PLC0415
            waveform = librosa.resample(waveform, orig_sr=sr, target_sr=target_sr)
        except ImportError:
            log.warning("librosa not installed; returning audio at native %d Hz", sr)
            target_sr = sr
    buf = io.BytesIO()
    sf.write(buf, waveform, target_sr, format="WAV", subtype="FLOAT")
    buf.seek(0)
    return Response(content=buf.read(), media_type="audio/wav")


# ── PyTorch model loading ─────────────────────────────────────────────────────

def _load_model(size: str) -> None:
    global _model_size, _device, _dtype
    from qwen_tts import Qwen3TTSModel  # noqa: PLC0415

    if size not in MODEL_IDS:
        raise ValueError(f"Unknown model_size: {size}")

    model_id = MODEL_IDS[size]
    _device, _dtype = _pick_device()

    cpu_count = os.cpu_count() or 4
    threads_per_worker = max(1, cpu_count // POOL_SIZE)
    torch.set_num_threads(threads_per_worker)

    log.info(
        "Loading %d×%s on %s (%s), %d threads/worker …",
        POOL_SIZE, model_id, _device, _dtype, threads_per_worker,
    )

    while not _pool.empty():
        try:
            _pool.get_nowait()
        except queue.Empty:
            break

    for i in range(POOL_SIZE):
        log.info("  worker %d/%d …", i + 1, POOL_SIZE)
        m = Qwen3TTSModel.from_pretrained(model_id, device_map=_device, dtype=_dtype)
        _pool.put(m)

    _model_size = size
    log.info("Pool ready: %d workers for %s", POOL_SIZE, model_id)


def _load_cv_model(size: str) -> None:
    """Load (or reload) the CustomVoice model. Must be called inside _cv_lock."""
    global _cv_model, _cv_model_size
    from qwen_tts import Qwen3TTSModel  # noqa: PLC0415

    if size not in CV_MODEL_IDS:
        raise ValueError(f"Unknown model_size for CustomVoice: {size}")

    model_id = CV_MODEL_IDS[size]
    device, dtype = _pick_device()
    log.info("Loading CustomVoice model %s on %s (%s) …", model_id, device, dtype)
    _cv_model = Qwen3TTSModel.from_pretrained(model_id, device_map=device, dtype=dtype)
    _cv_model_size = size
    log.info("CustomVoice model loaded: %s", model_id)


# ── MLX model loading ─────────────────────────────────────────────────────────

def _load_mlx_models(size: str) -> None:
    global _mlx_base_obj, _mlx_model_size

    if not _init_mlx_imports():
        raise RuntimeError("mlx-audio not available — install with: pip install mlx-audio")

    from mlx_audio.tts import load as mlx_load  # noqa: PLC0415

    base_id = MLX_IDS[("base", size)]
    log.info("Loading MLX base model %s …", base_id)
    _mlx_base_obj = mlx_load(base_id)
    log.info("MLX base model loaded (size=%s)", size)

    global _mlx_cv_obj
    cv_id = MLX_IDS[("custom", size)]
    log.info("Loading MLX CustomVoice model %s …", cv_id)
    _mlx_cv_obj = mlx_load(cv_id)
    log.info("MLX CustomVoice model loaded (size=%s)", size)

    _mlx_model_size = size
    log.info("MLX ready (size=%s)", size)


def _collect_mlx_audio(results) -> tuple[np.ndarray, int]:
    """Drain a model.generate() iterator and return (audio_array, sample_rate)."""
    chunks: list[np.ndarray] = []
    sr = 24000
    for result in results:
        chunks.append(np.asarray(result.audio, dtype=np.float32).flatten())
        sr = result.sample_rate
    if not chunks:
        raise RuntimeError("MLX model produced no audio")
    return np.concatenate(chunks), sr


def _ensure_mlx_cv_model(size: str) -> Any:
    """Load the CustomVoice model lazily on first use."""
    global _mlx_cv_obj
    if _mlx_cv_obj is not None:
        return _mlx_cv_obj
    from mlx_audio.tts import load as mlx_load  # noqa: PLC0415
    cv_id = MLX_IDS[("custom", size)]
    log.info("Loading MLX CustomVoice model %s …", cv_id)
    _mlx_cv_obj = mlx_load(cv_id)
    log.info("MLX CustomVoice model loaded")
    return _mlx_cv_obj


# ── FastAPI app + lifespan ────────────────────────────────────────────────────

def _load_mlx_models_safe(size: str) -> None:
    global _mlx_load_error
    _mlx_load_error = None
    try:
        _load_mlx_models(size)
    except Exception as e:
        _mlx_load_error = str(e)
        log.error("MLX model load failed: %s", e)


def _load_pytorch_models_safe(size: str) -> None:
    global _load_error
    _load_error = None
    try:
        _load_model(size)
    except Exception as e:
        _load_error = str(e)
        log.error("PyTorch model load failed: %s", e)


@asynccontextmanager
async def lifespan(app: FastAPI):
    if BACKEND == "mlx":
        # Submit to the dedicated MLX executor so load + inference share one thread.
        _mlx_executor.submit(_load_mlx_models_safe, DEFAULT_SIZE)
    else:
        threading.Thread(target=_load_pytorch_models_safe, args=(DEFAULT_SIZE,), daemon=True).start()
    yield


app = FastAPI(title="Orvox TTS", version="1.0.0", lifespan=lifespan)


class ConfigBody(BaseModel):
    model_size: str = DEFAULT_SIZE


class SynthBody(BaseModel):
    text: str
    speaker: Optional[str] = None
    reference_audio_path: Optional[str] = None
    preset: str = "audiobook"
    language: Optional[str] = "English"


# ── /health ───────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    if BACKEND == "mlx":
        if _mlx_load_error:
            raise HTTPException(status_code=503, detail=f"MLX load failed: {_mlx_load_error}")
        if _mlx_model_size is None:
            raise HTTPException(status_code=503, detail="Model loading")
        return {
            "status":     "ok",
            "model_size": _mlx_model_size,
            "device":     "Apple Silicon",
            "backend":    "mlx",
            "workers":    1,
            "cv_ready":   True,
        }
    else:
        if _load_error:
            raise HTTPException(status_code=503, detail=f"Model load failed: {_load_error}")
        if _model_size is None:
            raise HTTPException(status_code=503, detail="Model loading")
        device_label = "CPU" if _device == "cpu" else (
            f"CUDA ({_device})" if _device.startswith("cuda") else _device
        )
        return {
            "status":     "ok",
            "model_size": _model_size,
            "device":     device_label,
            "backend":    "pytorch",
            "workers":    POOL_SIZE,
            "cv_ready":   _cv_model is not None,
        }


# ── /config ───────────────────────────────────────────────────────────────────

def _configure_sync(size: str) -> dict:
    if BACKEND == "mlx":
        valid_sizes = {k[1] for k in MLX_IDS}
        if size not in valid_sizes:
            raise HTTPException(status_code=400, detail=f"Unknown model_size: {size}")
        if size != _mlx_model_size:
            _load_mlx_models(size)
    else:
        if size not in MODEL_IDS:
            raise HTTPException(status_code=400, detail=f"Unknown model_size: {size}")
        if size != _model_size:
            _load_model(size)
        if _cv_model is not None and size != _cv_model_size:
            with _cv_lock:
                _load_cv_model(size)
    active_size = _mlx_model_size if BACKEND == "mlx" else _model_size
    return {"status": "ok", "model_size": active_size}


@app.post("/config")
async def configure(body: ConfigBody):
    size = body.model_size.strip()
    try:
        loop = asyncio.get_event_loop()
        if BACKEND == "mlx":
            return await loop.run_in_executor(_mlx_executor, _configure_sync, size)
        return _configure_sync(size)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ── /synthesize helpers ───────────────────────────────────────────────────────

def _synth_pytorch(body: SynthBody, target_sr: int) -> Response:
    language = body.language or "English"

    if body.speaker:
        size = _model_size or DEFAULT_SIZE
        with _cv_lock:
            global _cv_load_error
            if _cv_model is None or _cv_model_size != size:
                _cv_load_error = None
                try:
                    _load_cv_model(size)
                except Exception as e:
                    _cv_load_error = str(e)
                    raise HTTPException(status_code=503, detail=f"CustomVoice load failed: {e}")
            try:
                wavs, sr = _cv_model.generate_custom_voice(
                    text=body.text, speaker=body.speaker, language=language,
                )
            except Exception as e:
                log.error("CustomVoice generation failed: %s", e)
                raise HTTPException(status_code=500, detail=str(e))
        return _wav_response(np.asarray(wavs[0], dtype=np.float32).squeeze(), sr, target_sr)

    if _model_size is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    if body.reference_audio_path:
        p = Path(body.reference_audio_path)
        if not p.exists():
            raise HTTPException(status_code=400, detail=f"Reference audio not found: {p}")
        ref_path, ref_text = p, None
    else:
        if not DEFAULT_REF_AUDIO.exists():
            raise HTTPException(status_code=500, detail="Default reference audio missing")
        ref_path, ref_text = DEFAULT_REF_AUDIO, DEFAULT_REF_TEXT

    worker = _pool.get()
    try:
        wavs, sr = worker.generate_voice_clone(
            text=body.text, language=language,
            ref_audio=str(ref_path), ref_text=ref_text,
            x_vector_only_mode=(ref_text is None),
        )
    except Exception as e:
        log.error("Generation failed: %s", e)
        _pool.put(worker)
        raise HTTPException(status_code=500, detail=str(e))
    _pool.put(worker)
    return _wav_response(np.asarray(wavs[0], dtype=np.float32).squeeze(), sr, target_sr)


def _synth_mlx(body: SynthBody, target_sr: int) -> Response:
    if _mlx_model_size is None:
        raise HTTPException(status_code=503, detail="MLX model not loaded")

    size = _mlx_model_size

    try:
        if body.speaker:
            # Built-in speaker: use CustomVoice model
            cv_model = _ensure_mlx_cv_model(size)
            results = cv_model.generate(text=body.text, voice=body.speaker)
        else:
            # Voice cloning: use base model with reference audio
            if body.reference_audio_path:
                p = Path(body.reference_audio_path)
                if not p.exists():
                    raise HTTPException(
                        status_code=400,
                        detail=f"Reference audio not found: {p}",
                    )
                ref_path, ref_text = p, None
            else:
                if not DEFAULT_REF_AUDIO.exists():
                    raise HTTPException(
                        status_code=500, detail="Default reference audio missing"
                    )
                ref_path, ref_text = DEFAULT_REF_AUDIO, DEFAULT_REF_TEXT

            results = _mlx_base_obj.generate(
                text=body.text,
                ref_audio=str(ref_path),
                ref_text=ref_text,
            )

        audio, sr = _collect_mlx_audio(results)
    except HTTPException:
        raise
    except Exception as e:
        log.error("MLX generation failed: %s", e)
        raise HTTPException(status_code=500, detail=str(e))

    return _wav_response(audio, sr, target_sr)


# ── /synthesize ───────────────────────────────────────────────────────────────

@app.post("/synthesize")
async def synthesize(body: SynthBody):
    target_sr = 16_000 if body.preset == "audiobook" else 22_050
    if BACKEND == "mlx":
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(_mlx_executor, _synth_mlx, body, target_sr)
    return _synth_pytorch(body, target_sr)


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
