"""
Orvox TTS server — FastAPI wrapper around Qwen3-TTS via the qwen-tts package.

Endpoints
---------
GET  /health      → {"status": "ok", "model_size": "1.7b", "device": "mps"}
POST /config      → {"model_size": "0.6b"} switches model in place
POST /synthesize  → WAV bytes (audio/wav)
                    body: {
                        "text": str,
                        "reference_audio_path": str | null,
                        "preset": "audiobook" | "podcast",
                        "language": str | null     (defaults to "English")
                    }
"""

from __future__ import annotations

import io
import logging
import os
import threading
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional

import numpy as np
import soundfile as sf
import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

from qwen_tts import Qwen3TTSModel

logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")
log = logging.getLogger("orvox-tts")

# ── Config ──────────────────────────────────────────────────────────────────

PORT = int(os.environ.get("TTS_PORT", "11435"))

MODEL_IDS: dict[str, str] = {
    "1.7b": "Qwen/Qwen3-TTS-12Hz-1.7B-Base",
    "0.6b": "Qwen/Qwen3-TTS-12Hz-0.6B-Base",
}

DEFAULT_SIZE = "1.7b"

SERVER_DIR = Path(__file__).resolve().parent
DEFAULT_REF_AUDIO = SERVER_DIR / "default_voice.wav"
DEFAULT_REF_TEXT  = (
    "Okay. Yeah. I resent you. I love you. I respect you. But you know what? "
    "You blew it! And thanks to you."
)

# ── Global model state ───────────────────────────────────────────────────────

_lock        = threading.Lock()
_model: Optional[Qwen3TTSModel] = None
_model_size: Optional[str]      = None
_device: str                    = "cpu"
_dtype: torch.dtype             = torch.float32


def _pick_device() -> tuple[str, torch.dtype]:
    # MPS disabled: PyTorch's structured_add_out_mps kernel triggers a Metal
    # validation abort (dispatchThreads:threadsPerThreadgroup: with invalid
    # compute function arguments) during qwen-tts inference on macOS 26.4 /
    # M-series. CPU is stable; revisit when PyTorch fixes the MPS kernel.
    if torch.cuda.is_available():
        return "cuda:0", torch.bfloat16
    return "cpu", torch.float32


def _load_model(size: str) -> None:
    global _model, _model_size, _device, _dtype

    if size not in MODEL_IDS:
        raise ValueError(f"Unknown model_size: {size}")

    model_id = MODEL_IDS[size]
    _device, _dtype = _pick_device()
    log.info("Loading %s on %s (%s) …", model_id, _device, _dtype)

    # flash_attention_2 isn't available on Mac; let qwen-tts pick its default (sdpa/eager).
    _model = Qwen3TTSModel.from_pretrained(
        model_id,
        device_map=_device,
        dtype=_dtype,
    )
    _model_size = size
    log.info("Model loaded: %s", model_id)


# ── FastAPI app + lifespan ────────────────────────────────────────────────────

_load_error: Optional[str] = None


def _load_model_async(size: str) -> None:
    global _load_error
    _load_error = None
    try:
        _load_model(size)
    except Exception as e:
        _load_error = str(e)
        log.error("Background model load failed: %s", e)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Kick the (slow) model load onto a background thread so uvicorn starts
    # accepting connections immediately. /health reports the load state.
    threading.Thread(target=_load_model_async, args=(DEFAULT_SIZE,), daemon=True).start()
    yield


app = FastAPI(title="Orvox TTS", version="1.0.0", lifespan=lifespan)


class ConfigBody(BaseModel):
    model_size: str = DEFAULT_SIZE


class SynthBody(BaseModel):
    text: str
    reference_audio_path: Optional[str] = None
    preset: str = "audiobook"
    language: Optional[str] = "English"


@app.get("/health")
def health():
    if _load_error:
        raise HTTPException(status_code=503, detail=f"Model load failed: {_load_error}")
    if _model is None:
        raise HTTPException(status_code=503, detail="Model loading")
    device_label = _device
    if _device == "mps":
        device_label = "Apple GPU (MPS)"
    elif _device == "cpu":
        device_label = "CPU"
    elif _device.startswith("cuda"):
        device_label = f"CUDA ({_device})"
    return {"status": "ok", "model_size": _model_size, "device": device_label}


@app.post("/config")
def configure(body: ConfigBody):
    size = body.model_size.strip()
    if size not in MODEL_IDS:
        raise HTTPException(status_code=400, detail=f"Unknown model_size: {size}")
    if size != _model_size:
        try:
            _load_model(size)
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))
    return {"status": "ok", "model_size": _model_size}


@app.post("/synthesize")
def synthesize(body: SynthBody):
    if _model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    # Pick reference audio: user-provided > bundled default.
    ref_path: Path
    ref_text: Optional[str]
    if body.reference_audio_path and Path(body.reference_audio_path).exists():
        ref_path = Path(body.reference_audio_path)
        # We don't have a transcript for user-imported audio; use x_vector_only_mode.
        ref_text = None
    else:
        if not DEFAULT_REF_AUDIO.exists():
            raise HTTPException(status_code=500, detail="Default reference audio missing")
        ref_path = DEFAULT_REF_AUDIO
        ref_text = DEFAULT_REF_TEXT

    target_sr = 16_000 if body.preset == "audiobook" else 22_050

    with _lock:
        try:
            wavs, sr = _model.generate_voice_clone(
                text=body.text,
                language=body.language or "English",
                ref_audio=str(ref_path),
                ref_text=ref_text,
                x_vector_only_mode=(ref_text is None),
            )
        except Exception as e:
            log.error("Generation failed: %s", e)
            raise HTTPException(status_code=500, detail=str(e))

    waveform = np.asarray(wavs[0], dtype=np.float32).squeeze()

    if sr != target_sr:
        try:
            import librosa
            waveform = librosa.resample(waveform, orig_sr=sr, target_sr=target_sr)
        except ImportError:
            log.warning("librosa not installed; returning audio at native %d Hz", sr)
            target_sr = sr

    buf = io.BytesIO()
    sf.write(buf, waveform, target_sr, format="WAV", subtype="FLOAT")
    buf.seek(0)
    return Response(content=buf.read(), media_type="audio/wav")


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
