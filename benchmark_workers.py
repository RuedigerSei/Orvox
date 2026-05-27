#!/usr/bin/env python3
"""
Benchmark: single MLX worker vs two parallel MLX workers for TTS.

Usage (quit the Orvox app first so nothing holds port 11435):

    cd "/Users/ruediger/Documents/Xcode Projects/Orvox"
    tts_venv/bin/python benchmark_workers.py

The script starts two server instances, waits for both models to load,
runs a warm-up round, then measures:
  - Sequential : all chunks sent one-at-a-time to port 11435
  - Parallel   : chunks distributed round-robin across both ports concurrently
"""

import concurrent.futures
import os
import subprocess
import sys
import time
from pathlib import Path

import requests

# ── Paths ─────────────────────────────────────────────────────────────────────

ROOT      = Path(__file__).resolve().parent
SERVER_PY = ROOT / "Orvox/Resources/tts_server/server.py"
PYTHON    = ROOT / "tts_venv/bin/python3"
REF_AUDIO = ROOT / "Orvox/Resources/tts_server/default_voice.wav"

for p in (SERVER_PY, PYTHON, REF_AUDIO):
    if not p.exists():
        sys.exit(f"Not found: {p}")

# ── Config ────────────────────────────────────────────────────────────────────

PORTS        = [11435, 11436]
HEALTH_WAIT  = 600   # seconds to wait for model load per server
WARMUP_TEXT  = "This is a short warm-up sentence to prime the MLX graph."

# Four ~120-word audiobook chunks
CHUNKS = [
    "The morning light fell across the wooden floor in long golden bars. "
    "Margaret stood at the window, watching the fog lift from the river below. "
    "She had lived in this house for forty years, long enough to know every creak "
    "of the staircase, every draft that crept under the kitchen door in winter. "
    "Yet this morning something felt different — not wrong, exactly, but altered, "
    "as though the familiar rooms had rearranged themselves overnight into a pattern "
    "she had not yet learned to read.",

    "The letter arrived on a Tuesday, which Margaret had always considered an "
    "unremarkable day. It was addressed in a hand she did not recognise, the ink "
    "slightly smeared as though written in haste or in poor light. She set it on "
    "the kitchen table beside her coffee cup and looked at it for a long moment "
    "before picking it up again. Whatever was inside had waited this long. "
    "It could wait another minute while she finished her coffee and prepared herself "
    "for whatever news it carried.",

    "Inside was a single sheet of paper, densely covered on both sides. "
    "The writing was small and precise, the words crowded together as though the "
    "writer had been afraid of running out of space. Margaret carried it to the "
    "window where the light was better and began to read. By the time she reached "
    "the bottom of the second page, her coffee had gone cold and the fog had "
    "lifted entirely from the river, leaving the water flat and bright beneath "
    "the late-morning sky.",

    "She read the letter twice more, then folded it carefully along its original "
    "creases and slid it back into the envelope. There was a name at the bottom "
    "she had not seen in over thirty years, a signature she would have recognised "
    "anywhere despite the decades. She sat down at the kitchen table and put her "
    "hands flat on the wood and breathed slowly, the way her doctor had taught her "
    "when her heart began to race. Outside, a pair of swallows crossed the window, "
    "moving fast and low over the river.",
]

# ── Helpers ───────────────────────────────────────────────────────────────────

def kill_port(port: int) -> None:
    subprocess.run(
        ["sh", "-c", f"lsof -ti:{port} | xargs kill -9 2>/dev/null; true"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def start_server(port: int) -> subprocess.Popen:
    env = {**os.environ, "TTS_PORT": str(port)}
    proc = subprocess.Popen(
        [str(PYTHON), str(SERVER_PY)],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc


def wait_healthy(port: int, timeout: int = HEALTH_WAIT) -> bool:
    url      = f"http://127.0.0.1:{port}/health"
    deadline = time.monotonic() + timeout
    last_dot = time.monotonic()
    while time.monotonic() < deadline:
        try:
            r = requests.get(url, timeout=5)
            if r.status_code == 200:
                return True
        except Exception:
            pass
        if time.monotonic() - last_dot >= 10:
            print(".", end="", flush=True)
            last_dot = time.monotonic()
        time.sleep(2)
    return False


def synthesize(port: int, text: str) -> float:
    url  = f"http://127.0.0.1:{port}/synthesize"
    body = {
        "text":                 text,
        "reference_audio_path": str(REF_AUDIO),
        "preset":               "audiobook",
    }
    t0 = time.monotonic()
    r  = requests.post(url, json=body, timeout=900)
    r.raise_for_status()
    return time.monotonic() - t0

# ── Tests ─────────────────────────────────────────────────────────────────────

def run_sequential(chunks: list, port: int) -> float:
    t0 = time.monotonic()
    for i, chunk in enumerate(chunks):
        elapsed = synthesize(port, chunk)
        print(f"    chunk {i+1}/{len(chunks)} → {elapsed:.1f}s")
    return time.monotonic() - t0


def run_parallel(chunks: list, ports: list) -> float:
    assignments = [(i, ports[i % len(ports)], chunk) for i, chunk in enumerate(chunks)]
    results     = [None] * len(chunks)

    t0 = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(chunks)) as pool:
        futures = {
            pool.submit(synthesize, port, chunk): (i, port)
            for i, port, chunk in assignments
        }
        for fut in concurrent.futures.as_completed(futures):
            i, port = futures[fut]
            elapsed = fut.result()
            results[i] = (elapsed, port)

    total = time.monotonic() - t0
    for i, (elapsed, port) in enumerate(results):
        print(f"    chunk {i+1}/{len(chunks)} → {elapsed:.1f}s  (port {port})")
    return total

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    procs = []
    try:
        print("\n── Clearing ports ───────────────────────────────────────")
        for port in PORTS:
            kill_port(port)
            print(f"  Cleared port {port}")
        time.sleep(1)

        print("\n── Starting servers ─────────────────────────────────────")
        for port in PORTS:
            proc = start_server(port)
            procs.append(proc)
            print(f"  Server PID {proc.pid} → port {port}")

        print("\n── Waiting for models to load ───────────────────────────")
        for port in PORTS:
            print(f"  Port {port} ", end="", flush=True)
            ok = wait_healthy(port)
            print(f" {'ready' if ok else 'TIMED OUT'}")
            if not ok:
                sys.exit("Aborting — server did not become healthy.")

        print("\n── Warm-up (one call per port, not timed) ───────────────")
        for port in PORTS:
            t = synthesize(port, WARMUP_TEXT)
            print(f"  Port {port}: {t:.1f}s")

        print(f"\n── Test 1: Sequential ({len(CHUNKS)} chunks → port {PORTS[0]}) ──")
        seq = run_sequential(CHUNKS, PORTS[0])
        print(f"  Total: {seq:.1f}s")

        print(f"\n── Test 2: Parallel ({len(CHUNKS)} chunks across {PORTS}) ──────")
        par = run_parallel(CHUNKS, PORTS)
        print(f"  Total: {par:.1f}s")

        print("\n── Results ──────────────────────────────────────────────")
        print(f"  Sequential : {seq:.1f}s")
        print(f"  Parallel   : {par:.1f}s")
        speedup = seq / par if par > 0 else 0
        print(f"  Speedup    : {speedup:.2f}×")
        if speedup >= 1.5:
            print("  → Two workers are worthwhile.")
        elif speedup >= 1.1:
            print("  → Modest gain; likely worth it only for long jobs.")
        else:
            print("  → No meaningful speedup; GPU is the bottleneck.")

    finally:
        print("\n── Stopping servers ─────────────────────────────────────")
        for proc in procs:
            proc.terminate()
            print(f"  Terminated PID {proc.pid}")
        for port in PORTS:
            kill_port(port)


if __name__ == "__main__":
    main()
