#!/usr/bin/env sh
# ---------------------------------------------------------------------------
# setup_python_env.sh - provision the Neurus Python environment (macOS/Linux).
#
# Creates a uv-managed virtual environment at lib/.venv, pinned to the version in
# lib/.python-version, and installs lib/environment.txt (pybind11).
#
# Idempotent: re-running with an unchanged pin + requirements exits early.
#
# Network notes: uv reads no pip configuration. If a system HTTP proxy blocks
# PyPI, export NO_PROXY='*' (direct) and/or UV_INDEX_URL to a reachable index.
# ---------------------------------------------------------------------------
set -eu

LIB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$LIB_DIR/.venv"
STAMP="$VENV/.neurus_env_stamp"
REQ="$LIB_DIR/environment.txt"
PIN="$(cat "$LIB_DIR/.python-version" 2>/dev/null || echo 3.12)"

if command -v shasum >/dev/null 2>&1; then
    HASH="$(shasum -a 256 "$REQ" | awk '{print $1}')"
else
    HASH="$(sha256sum "$REQ" | awk '{print $1}')"
fi
WANT="$PIN|$HASH"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ]; then
    echo "Using uv Python env at lib/.venv"
    exit 0
fi

if [ ! -d "$VENV" ]; then
    uv venv --python "$PIN" "$VENV"
fi
uv pip install --python "$VENV" -r "$REQ"
printf '%s' "$WANT" > "$STAMP"
echo "Using uv Python env at lib/.venv"
