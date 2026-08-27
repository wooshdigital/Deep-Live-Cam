# setup.ps1 — one-shot setup for a fresh PC (run via setup.bat).
#
# Recreates the exact working install this was authored from: Python 3.11
# venv, requirements.txt, the right ONNX runtime for THIS PC's GPU (CUDA on
# NVIDIA, DirectML otherwise), the three model files (fetched from this
# repo's "models-v1" GitHub release), and the default config files.
#
# Needs: gh_token.txt next to this script (fine-grained GitHub token,
# contents:read on wooshdigital/Deep-Live-Cam only) — the installer that
# downloaded this repo writes it. Internet + ~5GB disk. No git required.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$Repo = 'wooshdigital/Deep-Live-Cam'
$ReleaseTag = 'models-v1'
$TokenFile = Join-Path $PSScriptRoot 'gh_token.txt'

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# ---- token ----
if (-not (Test-Path $TokenFile)) { Fail "gh_token.txt not found next to setup.ps1 (the installer normally writes it)." }
$Token = (Get-Content $TokenFile -Raw).Trim()
if (-not $Token) { Fail 'gh_token.txt is empty.' }
$Headers = @{ Authorization = "Bearer $Token"; 'X-GitHub-Api-Version' = '2022-11-28' }

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
    Write-Host 'NVIDIA GPU found - keeping onnxruntime-gpu (CUDA).'
    $provider = 'cuda'
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
$rel = Invoke-RestMethod -Headers $Headers -Uri "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag"
foreach ($asset in $rel.assets) {
    $dest = Join-Path 'models' $asset.name
    if ((Test-Path $dest) -and ((Get-Item $dest).Length -eq $asset.size)) {
        Write-Host "  $($asset.name) already present - skipping"
        continue
    }
    Write-Host "  $($asset.name) ($([math]::Round($asset.size/1MB)) MB)..."
    # Asset download needs the octet-stream accept header on private repos.
    $h = $Headers.Clone(); $h['Accept'] = 'application/octet-stream'
    Invoke-WebRequest -Headers $h -Uri "https://api.github.com/repos/$Repo/releases/assets/$($asset.id)" -OutFile $dest
    if ((Get-Item $dest).Length -ne $asset.size) { Fail "$($asset.name): size mismatch after download." }
}

# ---- default config ----
Step 'Applying default config'
if ((Test-Path 'switch_states.default.json') -and -not (Test-Path 'switch_states.json')) {
    Copy-Item switch_states.default.json switch_states.json
}
if ((Test-Path 'working_models_sync_config.example.json') -and -not (Test-Path 'working_models_sync_config.json')) {
    Copy-Item working_models_sync_config.example.json working_models_sync_config.json
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
