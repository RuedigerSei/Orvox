"""
Orvox TTS server — FastAPI wrapper around Qwen3-TTS via the qwen-tts package.

Endpoints
---------
GET  /health      → {"status": "ok", "model_size": "1.7b", "device": "cpu", "cv_ready": false}
POST /config      → {"model_size": "0.6b"} switches both models in place
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

# Base models: voice cloning via reference audio
MODEL_IDS: dict[str, str] = {
    "1.7b": "Qwen/Qwen3-TTS-12Hz-1.7B-Base",
    "0.6b": "Qwen/Qwen3-TTS-12Hz-0.6B-Base",
}

# CustomVoice models: built-in named speakers (Vivian, Ryan, Aiden, …)
CV_MODEL_IDS: dict[str, str] = {
    "1.7b": "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
    "0.6b": "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice",
}

DEFAULT_SIZE = "1.7b"

SERVER_DIR = Path(__file__).resolve().parent
DEFAULT_REF_AUDIO = SERVER_DIR / "default_voice.wav"
DEFAULT_REF_TEXT  = (
    "Okay. Yeah. I resent you. I love you. I respect you. But you know what? "
    "You blew it! And thanks to you."
)

# ── Base model state ─────────────────────────────────────────────────────────

_lock        = threading.Lock()
_model: Optional[Qwen3TTSModel] = None
_model_size: Optional[str]      = None
_device: str                    = "cpu"
_dtype: torch.dtype             = torch.float32
_load_error: Optional[str]      = None

# ── CustomVoice model state ──────────────────────────────────────────────────

_cv_lock: threading.Lock        = threading.Lock()
_cv_model: Optional[Qwen3TTSModel] = None
_cv_model_size: Optional[str]      = None
_cv_load_error: Optional[str]      = None


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

    _model = Qwen3TTSModel.from_pretrained(
        model_id,
        device_map=_device,
        dtype=_dtype,
    )
    _model_size = size
    log.info("Model loaded: %s", model_id)


def _load_cv_model(size: str) -> None:
    """Load (or reload) the CustomVoice model. Must be called inside _cv_lock."""
    global _cv_model, _cv_model_size

    if size not in CV_MODEL_IDS:
        raise ValueError(f"Unknown model_size for CustomVoice: {size}")

    model_id = CV_MODEL_IDS[size]
    device, dtype = _pick_device()
    log.info("Loading CustomVoice model %s on %s (%s) …", model_id, device, dtype)

    _cv_model = Qwen3TTSModel.from_pretrained(
        model_id,
        device_map=device,
        dtype=dtype,
    )
    _cv_model_size = size
    log.info("CustomVoice model loaded: %s", model_id)


# ── FastAPI app + lifespan ────────────────────────────────────────────────────

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
    # Base model loads at startup; CustomVoice model loads lazily on first use.
    threading.Thread(target=_load_model_async, args=(DEFAULT_SIZE,), daemon=True).start()
    yield


app = FastAPI(title="Orvox TTS", version="1.0.0", lifespan=lifespan)


class ConfigBody(BaseModel):
    model_size: str = DEFAULT_SIZE


class SynthBody(BaseModel):
    text: str
    speaker: Optional[str] = None          # built-in voice name → CustomVoice model
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
    return {
        "status": "ok",
        "model_size": _model_size,
        "device": device_label,
        "cv_ready": _cv_model is not None,
    }


@app.post("/config")
def configure(body: ConfigBody):
    size = body.model_size.strip()
    if size not in MODEL_IDS:
        raise HTTPException(status_code=400, detail=f"Unknown model_size: {size}")
    try:
        if size != _model_size:
            _load_model(size)
        # Keep CustomVoice model in sync only if it was already loaded.
        if _cv_model is not None and size != _cv_model_size:
            with _cv_lock:
                _load_cv_model(size)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    return {"status": "ok", "model_size": _model_size}


@app.post("/synthesize")
def synthesize(body: SynthBody):
    language  = body.language or "English"
    target_sr = 16_000 if body.preset == "audiobook" else 22_050

    # ── Path 1: built-in speaker via CustomVoice model ────────────────────
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
                    log.error("CustomVoice model load failed: %s", e)
                    raise HTTPException(
                        status_code=503,
                        detail=f"CustomVoice model load failed: {e}",
                    )
            try:
                wavs, sr = _cv_model.generate_custom_voice(
                    text=body.text,
                    speaker=body.speaker,
                    language=language,
                )
            except Exception as e:
                log.error("CustomVoice generation failed: %s", e)
                raise HTTPException(status_code=500, detail=str(e))

        waveform = np.asarray(wavs[0], dtype=np.float32).squeeze()
        return _wav_response(waveform, sr, target_sr)

    # ── Path 2: voice clone via Base model ────────────────────────────────
    if _model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    ref_path: Path
    ref_text: Optional[str]
    if body.reference_audio_path and Path(body.reference_audio_path).exists():
        ref_path = Path(body.reference_audio_path)
        ref_text = None
    else:
        if not DEFAULT_REF_AUDIO.exists():
            raise HTTPException(status_code=500, detail="Default reference audio missing")
        ref_path = DEFAULT_REF_AUDIO
        ref_text = DEFAULT_REF_TEXT

    with _lock:
        try:
            wavs, sr = _model.generate_voice_clone(
                text=body.text,
                language=language,
                ref_audio=str(ref_path),
                ref_text=ref_text,
                x_vector_only_mode=(ref_text is None),
            )
        except Exception as e:
            log.error("Generation failed: %s", e)
            raise HTTPException(status_code=500, detail=str(e))

    waveform = np.asarray(wavs[0], dtype=np.float32).squeeze()
    return _wav_response(waveform, sr, target_sr)


def _wav_response(waveform: np.ndarray, sr: int, target_sr: int) -> Response:
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
