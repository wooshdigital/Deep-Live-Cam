# setup.ps1 — one-shot setup for a fresh PC (run via setup.bat).
#
# Recreates the exact working install this was authored from: Python 3.11
# venv, requirements.txt, the right ONNX runtime for THIS PC's GPU (CUDA on
# NVIDIA, DirectML otherwise), the three model files (fetched from this
# repo's "models-v1" GitHub release), and the default config files.
#
# This repo is PUBLIC — no GitHub auth anywhere. The one real secret is the
# Kinetix API key for Working-Models photo sync: the team installer writes it
# to kinetix_key.txt (gitignored) and this script wires it into the sync
# config. Without it everything still installs; only photo sync stays off.
# Internet + ~5GB disk. No git required.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$Repo = 'wooshdigital/Deep-Live-Cam'
$ReleaseTag = 'models-v1'
$KinetixKeyFile = Join-Path $PSScriptRoot 'kinetix_key.txt'

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# ---- python 3.11 ----
Step 'Checking Python 3.11'
$py = $null
try { & py -3.11 --version *> $null; if ($LASTEXITCODE -eq 0) { $py = 'py -3.11' } } catch {}
if (-not $py) {
    try { $v = & python --version 2>&1; if ("$v" -match '3\.11\.') { $py = 'python' } } catch {}
}
if (-not $py) {
    Write-Host 'Python 3.11 not found - installing via winget...'
    winget install -e --id Python.Python.3.11 --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { Fail 'Could not install Python 3.11. Install it manually from python.org, then re-run setup.bat.' }
    # winget updates PATH for new shells only; use the launcher.
    $py = 'py -3.11'
}
Write-Host "Using: $py"

# ---- venv + deps ----
Step 'Creating venv + installing dependencies (this takes a while)'
if (-not (Test-Path 'venv')) {
    Invoke-Expression "$py -m venv venv"
}
$pip = '.\venv\Scripts\pip.exe'
& $pip install --upgrade pip -q
& $pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) { Fail 'pip install -r requirements.txt failed.' }

# ---- pick the ONNX runtime for this GPU ----
Step 'Detecting GPU'
$hasNvidia = $false
try { & nvidia-smi *> $null; if ($LASTEXITCODE -eq 0) { $hasNvidia = $true } } catch {}
if ($hasNvidia) {
    # nvidia-smi only proves a DRIVER is present. onnxruntime-gpu additionally
    # needs the CUDA 12 runtime and cuDNN 9 DLLs, which are NOT bundled with the
    # wheel and are absent on a machine without the CUDA toolkit. Without them
    # onnxruntime logs "cudnn64_9.dll is missing" and silently falls back to
    # CPUExecutionProvider -- the app still runs, just many times slower, while
    # launch.bat claims "provider: cuda". Silent and slow is the worst outcome,
    # so prove CUDA actually loads before trusting it.
    Write-Host 'NVIDIA GPU found - verifying CUDA runtime...'
    $probe = @'
import sys
try:
    import numpy as np, onnx, onnxruntime as ort
    from onnx import helper, TensorProto
    t = helper.make_tensor_value_info("x", TensorProto.FLOAT, [1])
    g = helper.make_graph([helper.make_node("Identity", ["x"], ["y"])], "p", [t],
                          [helper.make_tensor_value_info("y", TensorProto.FLOAT, [1])])
    m = helper.make_model(g, opset_imports=[helper.make_opsetid("", 13)])
    so = ort.SessionOptions(); so.log_severity_level = 4
    s = ort.InferenceSession(m.SerializeToString(), so, providers=["CUDAExecutionProvider"])
    print("OK" if "CUDAExecutionProvider" in s.get_providers() else "FALLBACK")
except Exception as e:
    print("FALLBACK")
'@
    $probeFile = Join-Path $env:TEMP 'dlc_cuda_probe.py'
    Set-Content -Path $probeFile -Value $probe -Encoding UTF8
    $cudaOk = (& '.\venv\Scripts\python.exe' $probeFile 2>$null | Select-Object -Last 1)
    Remove-Item $probeFile -ErrorAction SilentlyContinue
    if ($cudaOk -eq 'OK') {
        Write-Host 'CUDA runtime OK - keeping onnxruntime-gpu.'
        $provider = 'cuda'
    } else {
        # DirectML works on NVIDIA too and needs no toolkit, so this still gives
        # real GPU acceleration -- just via DX12 instead of CUDA.
        Write-Host 'CUDA runtime incomplete (cuDNN/CUDA libs missing) - switching to DirectML.'
        & $pip uninstall -y onnxruntime-gpu
        & $pip install onnxruntime-directml==1.24.4
        if ($LASTEXITCODE -ne 0) { Fail 'Could not install onnxruntime-directml.' }
        $provider = 'dml'
    }
} else {
    # Same swap the original working install used: requirements pins
    # onnxruntime-gpu, which is useless without CUDA - replace with DirectML.
    Write-Host 'No NVIDIA GPU - switching to onnxruntime-directml.'
    & $pip uninstall -y onnxruntime-gpu
    & $pip install onnxruntime-directml==1.24.4
    if ($LASTEXITCODE -ne 0) { Fail 'Could not install onnxruntime-directml.' }
    $provider = 'dml'
}

# ---- models from the GitHub release ----
Step 'Downloading model files (~1.1GB)'
New-Item -ItemType Directory -Force models | Out-Null
$rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag"
foreach ($asset in $rel.assets) {
    $dest = Join-Path 'models' $asset.name
    if ((Test-Path $dest) -and ((Get-Item $dest).Length -eq $asset.size)) {
        Write-Host "  $($asset.name) already present - skipping"
        continue
    }
    Write-Host "  $($asset.name) ($([math]::Round($asset.size/1MB)) MB)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest
    if ((Get-Item $dest).Length -ne $asset.size) { Fail "$($asset.name): size mismatch after download." }
}

# ---- default config ----
Step 'Applying default config'
if ((Test-Path 'switch_states.default.json') -and -not (Test-Path 'switch_states.json')) {
    Copy-Item switch_states.default.json switch_states.json
}
# Working-Models photo sync: wire in the real Kinetix key when the installer
# provided one; otherwise fall back to the example (sync disabled until the
# key is filled in by hand).
if (Test-Path $KinetixKeyFile) {
    $kkey = (Get-Content $KinetixKeyFile -Raw).Trim()
    if ($kkey) {
        @{ api_url = 'https://kinetix.roochedigital.com/api'; api_key = $kkey } |
            ConvertTo-Json | Out-File -Encoding ascii working_models_sync_config.json
        Write-Host 'Kinetix photo sync configured.'
    }
} elseif (-not (Test-Path 'working_models_sync_config.json')) {
    Copy-Item working_models_sync_config.example.json working_models_sync_config.json
    Write-Host 'NOTE: no Kinetix key provided - photo sync stays off until the key is set.' -ForegroundColor Yellow
}

# ---- launch.bat for this PC's provider ----
@"
@echo off
cd /d "%~dp0"
"%~dp0venv\Scripts\python.exe" sync_working_models.py
"%~dp0venv\Scripts\python.exe" run.py --execution-provider $provider
pause
"@ | Out-File -Encoding ascii launch.bat

Step 'Done'
Write-Host "Setup complete. Start the app with launch.bat (provider: $provider)." -ForegroundColor Green
