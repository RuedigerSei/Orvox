"""
Orvox TTS server — FastAPI/MLX wrapper around Qwen3-TTS (Apple Silicon).

Endpoints
---------
GET  /health      → {status, model_size, device, backend, workers}
POST /config      → {"model_size": "0.6b"} switches models in place
POST /synthesize  → WAV bytes (audio/wav)
                    body: {
                        "text": str,
                        "reference_audio_path": str | null,
                        "preset": "audiobook" | "podcast"
                    }
                    Falls back to bundled default_voice.wav when reference_audio_path is null.
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import io
import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Optional

import numpy as np
import soundfile as sf
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")
log = logging.getLogger("orvox-tts")

# ── Config ────────────────────────────────────────────────────────────────────

PORT         = int(os.environ.get("TTS_PORT", "11435"))
DEFAULT_SIZE = "1.7b"

MLX_IDS: dict[str, str] = {
    "1.7b": "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit",
    "0.6b": "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
}

SERVER_DIR        = Path(__file__).resolve().parent
DEFAULT_REF_AUDIO = SERVER_DIR / "default_voice.wav"
DEFAULT_REF_TEXT  = (
    "Okay. Yeah. I resent you. I love you. I respect you. But you know what? "
    "You blew it! And thanks to you."
)

# ── MLX state ─────────────────────────────────────────────────────────────────

# Single-threaded executor: MLX Metal streams are thread-local, so every MLX
# operation (load + inference) must run on the same thread.
_mlx_executor    = concurrent.futures.ThreadPoolExecutor(max_workers=1)
_mlx_base_obj:   Optional[Any] = None
_mlx_model_size: Optional[str] = None
_mlx_load_error: Optional[str] = None

# ── Helpers ───────────────────────────────────────────────────────────────────

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

# ── Model loading ─────────────────────────────────────────────────────────────

def _load_mlx_models(size: str) -> None:
    global _mlx_base_obj, _mlx_model_size

    try:
        import mlx_audio.tts  # noqa: PLC0415
    except ImportError as e:
        raise RuntimeError(f"mlx-audio not available — install with: pip install mlx-audio") from e

    from mlx_audio.tts import load as mlx_load  # noqa: PLC0415

    model_id = MLX_IDS[size]
    log.info("Loading MLX model %s …", model_id)
    _mlx_base_obj = mlx_load(model_id)
    log.info("MLX model loaded (size=%s)", size)

    _mlx_model_size = size
    log.info("MLX ready (size=%s)", size)


def _load_mlx_models_safe(size: str) -> None:
    global _mlx_load_error
    _mlx_load_error = None
    try:
        _load_mlx_models(size)
    except Exception as e:
        _mlx_load_error = str(e)
        log.error("MLX model load failed: %s", e)

# ── FastAPI app ───────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    _mlx_executor.submit(_load_mlx_models_safe, DEFAULT_SIZE)
    yield


app = FastAPI(title="Orvox TTS", version="1.0.0", lifespan=lifespan)


class ConfigBody(BaseModel):
    model_size: str = DEFAULT_SIZE


class SynthBody(BaseModel):
    text: str
    reference_audio_path: Optional[str] = None
    preset: str = "audiobook"

# ── /health ───────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
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
    }

# ── /config ───────────────────────────────────────────────────────────────────

def _configure_sync(size: str) -> dict:
    if size not in MLX_IDS:
        raise HTTPException(status_code=400, detail=f"Unknown model_size: {size}")
    if size != _mlx_model_size:
        _load_mlx_models(size)
    return {"status": "ok", "model_size": _mlx_model_size}


@app.post("/config")
async def configure(body: ConfigBody):
    try:
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(_mlx_executor, _configure_sync, body.model_size.strip())
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# ── /synthesize ───────────────────────────────────────────────────────────────

def _synth_mlx(body: SynthBody, target_sr: int) -> Response:
    if _mlx_model_size is None:
        raise HTTPException(status_code=503, detail="MLX model not loaded")

    size = _mlx_model_size

    try:
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


@app.post("/synthesize")
async def synthesize(body: SynthBody):
    target_sr = 16_000 if body.preset == "audiobook" else 22_050
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(_mlx_executor, _synth_mlx, body, target_sr)

# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
