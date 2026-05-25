#!/usr/bin/env bash
# Orvox — one-shot setup script
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "=== Orvox Setup ==="

# ── 1. XcodeGen ──────────────────────────────────────────────
if ! command -v xcodegen &>/dev/null; then
  echo "Installing XcodeGen via Homebrew…"
  brew install xcodegen
fi
echo "Generating Xcode project…"
xcodegen generate

# ── 2. Pick Python (needs 3.10–3.12; PyTorch has no 3.13 wheels yet) ────────
PYTHON=""
for candidate in python3.12 python3.11 python3.10; do
  if command -v "$candidate" &>/dev/null; then
    PYTHON="$candidate"
    break
  fi
done

if [ -z "$PYTHON" ]; then
  echo "⚠️  Python 3.10–3.12 not found. PyTorch may not install."
  echo "   Install with: brew install python@3.11"
  echo "   Then re-run this script."
  exit 1
fi

echo "Using $PYTHON ($(${PYTHON} --version))"

# ── 3. Python venv ────────────────────────────────────────────
VENV_DIR="$ROOT/tts_venv"
SERVER_DIR="$ROOT/Orvox/Resources/tts_server"

if [ ! -d "$VENV_DIR" ]; then
  echo "Creating virtual environment…"
  "$PYTHON" -m venv "$VENV_DIR"
fi

PIP="$VENV_DIR/bin/pip"
echo "Upgrading pip…"
"$PIP" install --upgrade pip -q

# Install PyTorch first from the stable wheel index (covers MPS on Apple Silicon)
echo "Installing PyTorch…"
"$PIP" install torch \
  --extra-index-url https://download.pytorch.org/whl/cpu \
  -q

# Install remaining dependencies
echo "Installing TTS dependencies…"
"$PIP" install -r "$SERVER_DIR/requirements.txt" -q

echo ""
echo "✓ Done! Open Orvox.xcodeproj in Xcode to build."
echo ""
echo "Note: First launch downloads the Qwen3-TTS 1.7B model (~3.5 GB)."
echo "      Subsequent launches are instant."
