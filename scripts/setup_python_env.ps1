#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# setup_python_env.ps1 - provision the Neurus Python environment (Windows).
#
# Creates a uv-managed virtual environment at lib/.venv, pinned to the version in
# lib/.python-version, and installs lib/environment.txt (pybind11, used by the
# C++ scripting layer at build time).
#
# Idempotent: re-running with an unchanged pin + requirements exits early.
# Prints "Using uv Python env at lib/.venv" on success so CI can assert it.
#
# Network notes: uv reads no pip configuration. If a system HTTP proxy blocks
# PyPI, set NO_PROXY=* (direct) and/or UV_INDEX_URL to a reachable index, e.g.
#   $env:NO_PROXY='*'; $env:UV_INDEX_URL='https://pypi.tuna.tsinghua.edu.cn/simple'
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

$LibDir  = Split-Path -Parent $PSScriptRoot
$Venv    = Join-Path $LibDir '.venv'
$Stamp   = Join-Path $Venv '.neurus_env_stamp'
$Req     = Join-Path $LibDir 'environment.txt'
$PinFile = Join-Path $LibDir '.python-version'

$Pin = if (Test-Path $PinFile) { (Get-Content $PinFile -Raw).Trim() } else { '3.12' }
$Want = "$Pin|$((Get-FileHash -Algorithm SHA256 $Req).Hash)"

function Invoke-Checked([scriptblock]$Block, [string]$What) {
    & $Block
    if ($LASTEXITCODE -ne 0) { throw "setup_python_env: '$What' failed (exit $LASTEXITCODE)" }
}

if ((Test-Path $Stamp) -and ((Get-Content $Stamp -Raw).Trim() -eq $Want)) {
    Write-Host 'Using uv Python env at lib/.venv'
    exit 0
}

if (-not (Test-Path $Venv)) {
    Invoke-Checked { uv venv --python $Pin $Venv } 'uv venv'
}
Invoke-Checked { uv pip install --python $Venv -r $Req } 'uv pip install'
Set-Content -Path $Stamp -Value $Want
Write-Host 'Using uv Python env at lib/.venv'
