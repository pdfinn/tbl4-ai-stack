# ─── tbl4-ai-stack Setup (Windows) ─────────────────────────────────────────────
# Brings up the unified classroom stack: OpenWebUI + n8n + auto-bootstrapper
# and (optionally) containerised Ollama and the mcpo MCP proxy.
#
# Profiles are driven by the PROFILES line in .env (comma-separated):
#   local — Ollama runs on the host (default; uses GPU)
#   cloud — Ollama runs as a container in the stack
#   mcp   — adds the mcpo proxy
# Combine freely, e.g. PROFILES=cloud,mcp
#
# Students: just double-click setup_windows.bat in File Explorer.
# This file is the internal script the wrapper calls.
#
# -WSLSetup re-invokes this script elevated to do the one-time, admin-only
# WSL 2 work (see Invoke-WslSetup). Students never pass it by hand.
param([switch]$WSLSetup)

$ErrorActionPreference = "Stop"

function Info($msg)  { Write-Host "[OK]  $msg" -ForegroundColor Green }
function Warn($msg)  { Write-Host "[!!]  $msg" -ForegroundColor Yellow }
function Fail($msg)  { Write-Host "[ERR] $msg" -ForegroundColor Red; exit 1 }

# ─── WSL 2 preflight ───────────────────────────────────────────────────────────
# Docker Desktop's engine runs on the WSL 2 backend, and on a fresh Windows
# machine that backend is the usual blocker: the Windows features aren't enabled,
# or the Linux kernel component is stale ("WSL 2 requires an update to its kernel
# component"). We fix that automatically — the one step that needs admin —
# before we ever touch Docker. State flags live under LOCALAPPDATA so we don't
# re-prompt for elevation on every run.
$Tbl4StateDir  = Join-Path $env:LOCALAPPDATA "tbl4-ai-stack"
$WslReadyFlag  = Join-Path $Tbl4StateDir "wsl-ready"
$WslRebootFlag = Join-Path $Tbl4StateDir "wsl-reboot-needed"

function Test-WslHealthy {
    if (-not (Test-Path $WslReadyFlag)) { return $false }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    & wsl.exe --status 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Runs ELEVATED (re-invoked via -WSLSetup). Enables the WSL / Virtual Machine
# Platform Windows features and updates the kernel. Signals back to the
# non-admin parent through flag files: wsl-reboot-needed (features were just
# turned on, a restart is required) or wsl-ready (everything is in place).
function Invoke-WslSetup {
    New-Item -ItemType Directory -Force -Path $Tbl4StateDir | Out-Null
    Remove-Item $WslReadyFlag, $WslRebootFlag -ErrorAction SilentlyContinue

    $rebootNeeded = $false
    foreach ($feature in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")) {
        if ((Get-WindowsOptionalFeature -Online -FeatureName $feature).State -ne "Enabled") {
            Write-Host "Enabling Windows feature: $feature"
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
            if ($result.RestartNeeded) { $rebootNeeded = $true }
        }
    }

    if ($rebootNeeded) {
        New-Item -ItemType File -Force -Path $WslRebootFlag | Out-Null
        return
    }

    # Features are on; bring the kernel up to date. --web-download avoids a hard
    # dependency on the Microsoft Store (often disabled on school machines).
    Write-Host "Updating the WSL 2 kernel..."
    & wsl.exe --update 2>$null
    if ($LASTEXITCODE -ne 0) { & wsl.exe --update --web-download 2>$null }
    & wsl.exe --set-default-version 2 2>$null | Out-Null

    New-Item -ItemType File -Force -Path $WslReadyFlag | Out-Null
}

# Elevated entry point — do only the WSL work and exit.
if ($WSLSetup) { Invoke-WslSetup; exit 0 }

# Ensures the WSL 2 backend is present and current before we rely on Docker.
# Self-elevates once (UAC) to do the admin-only feature/kernel work.
function Ensure-Wsl {
    $build = [int][System.Environment]::OSVersion.Version.Build
    if ($build -lt 19041) {
        Fail "This stack needs WSL 2, which requires Windows 10 version 2004 (build 19041) or newer.`nYou're on build $build. Run Windows Update, restart, and try again."
    }

    if (Test-WslHealthy) { Info "WSL 2 backend is ready"; return }

    Warn "Setting up the WSL 2 backend Docker needs. Windows will ask for administrator approval."
    Remove-Item $WslRebootFlag -ErrorAction SilentlyContinue
    try {
        Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", "`"$PSCommandPath`"", "-WSLSetup") | Out-Null
    } catch {
        Fail "Administrator approval is required to enable WSL 2. Re-run setup and choose 'Yes' at the prompt, or enable WSL manually:`nhttps://learn.microsoft.com/windows/wsl/install"
    }

    if (Test-Path $WslRebootFlag) {
        Remove-Item $WslRebootFlag -ErrorAction SilentlyContinue
        Write-Host ""
        Warn "Windows turned on the features WSL 2 needs, but they only take effect after a restart."
        Write-Host "  1. Restart your computer."
        Write-Host "  2. Double-click setup_windows.bat again to finish."
        Write-Host ""
        exit 0
    }

    if (-not (Test-WslHealthy)) {
        Fail "WSL 2 setup didn't complete. This usually means hardware virtualization is turned off in your PC's BIOS/UEFI.`nReboot into BIOS/UEFI, enable 'Virtualization' (Intel VT-x / AMD-V / SVM), save, then re-run setup.`nMore help: https://learn.microsoft.com/windows/wsl/install"
    }
    Info "WSL 2 backend is ready"
}

Write-Host ""
Write-Host "========================================="
Write-Host "  Tarkas Brainlab IV — Stack Setup"
Write-Host "========================================="
Write-Host ""

# ─── .env ────────────────────────────────────────────────────────────────────
if (-not (Test-Path .env)) {
    Copy-Item .env.example .env
    Info "Created .env from .env.example"
}

function Read-EnvFile {
    $vars = @{}
    Get-Content .env | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            $vars[$matches[1].Trim()] = $matches[2].Trim()
        }
    }
    return $vars
}

function Set-EnvVar($name, $value) {
    $envContent = Get-Content .env
    if ($envContent -match "^${name}=") {
        $envContent = $envContent -replace "^${name}=.*", "${name}=$value"
        [System.IO.File]::WriteAllText((Resolve-Path .env), (($envContent -join "`n") + "`n"))
    } else {
        Add-Content .env "${name}=$value"
    }
}

$envVars = Read-EnvFile

# Generate a WEBUI_SECRET_KEY on first run.
if (-not $envVars.ContainsKey("WEBUI_SECRET_KEY") -or [string]::IsNullOrEmpty($envVars["WEBUI_SECRET_KEY"])) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $secret = ([BitConverter]::ToString($bytes) -replace '-', '').ToLower()
    Set-EnvVar "WEBUI_SECRET_KEY" $secret
    Info "Generated WEBUI_SECRET_KEY"
    $envVars = Read-EnvFile
}

$Profiles  = if ($envVars["PROFILES"])   { $envVars["PROFILES"]   } else { "local"   }
$Model     = if ($envVars["MODEL"])      { $envVars["MODEL"]      } else { "mistral" }
$WebuiPort = if ($envVars["WEBUI_PORT"]) { $envVars["WEBUI_PORT"] } else { "3000"    }
$N8nPort   = if ($envVars["N8N_PORT"])   { $envVars["N8N_PORT"]   } else { "5678"    }

$profilesLc = ",$($Profiles.ToLower()),"
$useCloud = $profilesLc.Contains(",cloud,")
$useMcp   = $profilesLc.Contains(",mcp,")
$useLocal = $profilesLc.Contains(",local,") -or (-not $useCloud)

Info "Profiles: $Profiles"

# Set Ollama URL according to profile.
if ($useCloud) {
    $ollamaUrl = "http://ollama:11434"
} else {
    $ollamaUrl = "http://host.docker.internal:11434"
}
Set-EnvVar "OLLAMA_BASE_URL" $ollamaUrl
Set-EnvVar "OLLAMA_HOST"     $ollamaUrl

# ─── WSL 2 backend ───────────────────────────────────────────────────────────
# Must run before Docker: Docker Desktop's engine won't start without it, and
# this is the step students get stuck on most.
Ensure-Wsl

# ─── Docker ──────────────────────────────────────────────────────────────────
try { $null = Get-Command docker -ErrorAction Stop }
catch {
    # Hand off to the official Docker Desktop installer rather than silently
    # winget-installing it: the GUI surfaces the WSL 2 option and the EULA, and
    # Docker Desktop often needs a sign-out/restart before its CLI is on PATH.
    Warn "Docker Desktop isn't installed yet."
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
    $installer = Join-Path $env:TEMP "DockerDesktopInstaller.exe"
    $url = "https://desktop.docker.com/win/main/$arch/Docker Desktop Installer.exe"
    try {
        Write-Host "Downloading the official Docker Desktop installer ($arch)..."
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
    } catch {
        Fail "Couldn't download Docker Desktop automatically. Install it by hand, then re-run setup:`nhttps://www.docker.com/products/docker-desktop/"
    }
    Write-Host ""
    Warn "Launching the Docker Desktop installer."
    Write-Host "  - Keep the 'Use WSL 2 instead of Hyper-V' option checked."
    Write-Host "  - When it finishes it may ask you to sign out or restart."
    Write-Host "  - Then double-click setup_windows.bat again to finish."
    Start-Process -FilePath $installer
    Write-Host ""
    Read-Host "Press Enter to close this window"
    exit 0
}

function Test-DockerUp { docker info 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) }
if (-not (Test-DockerUp)) {
    $dockerExe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerExe) {
        Warn "Docker is not running. Starting Docker Desktop..."
        Start-Process -FilePath $dockerExe | Out-Null
        # Docker Desktop can take 30–60s to come up on first launch.
        for ($i = 0; $i -lt 90; $i++) {
            if (Test-DockerUp) { break }
            Start-Sleep -Seconds 2
        }
        if (-not (Test-DockerUp)) {
            Fail "Docker Desktop didn't become ready within 3 minutes. Open it manually and re-run."
        }
    } else {
        Fail "Docker is not running and Docker Desktop is not installed at '$dockerExe'. Install Docker Desktop:`nhttps://www.docker.com/products/docker-desktop/"
    }
}
Info "Docker is running"

# ─── Host Ollama (local profile only) ────────────────────────────────────────
if ($useLocal -and -not $useCloud) {
    $ollamaInstalled = $false
    try { $null = Get-Command ollama -ErrorAction Stop; $ollamaInstalled = $true } catch {}

    if (-not $ollamaInstalled) {
        Write-Host ""
        Warn "Installing Ollama..."
        try {
            winget install --id Ollama.Ollama --accept-source-agreements --accept-package-agreements
        } catch {
            Fail "Could not install Ollama. Install manually from:`nhttps://ollama.com/download/windows"
        }
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
        # Marker so teardown knows *this script* installed Ollama. Without it,
        # teardown will not touch a host Ollama the user installed separately.
        Set-Content -Path .tbl4-installed-ollama -Value "Ollama.Ollama"
        Write-Host ""
    }
    Info "Ollama is installed"

    function Test-OllamaUp {
        try {
            $null = Invoke-RestMethod -Uri "http://localhost:11434/api/version" -TimeoutSec 5
            return $true
        } catch { return $false }
    }

    if (-not (Test-OllamaUp)) {
        $trayApp = Get-Process -Name "ollama app" -ErrorAction SilentlyContinue
        if (-not $trayApp) {
            Write-Host ""
            Warn "Starting Ollama..."
            $trayAppPath = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama app.exe"
            if (Test-Path -LiteralPath $trayAppPath) {
                Start-Process -FilePath $trayAppPath
            } else {
                Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
            }
        } else {
            Write-Host ""
            Warn "Ollama is starting up, waiting..."
        }
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 1
            if (Test-OllamaUp) { break }
        }
        if (-not (Test-OllamaUp)) {
            Fail "Ollama did not respond within 60 seconds. Open the Ollama app from the Start menu and re-run this setup."
        }
    }
    Info "Ollama is running"

    Write-Host ""
    Write-Host "Pulling model: $Model (first time can take a few minutes)"
    Write-Host ""
    # Suppress OLLAMA_HOST so the CLI talks to localhost, not the in-container URL.
    $prev = $env:OLLAMA_HOST; $env:OLLAMA_HOST = $null
    try {
        & ollama pull $Model

        # Some Mistral library templates (e.g. ministral-3:3b) call template
        # helpers — currentDate, yesterdayDate — that older Ollama builds
        # don't define, breaking every chat. If the local Ollama can't
        # render the template, rebuild the model under the same tag with
        # those references substituted out.
        & ollama show --template $Model 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Warn "Model template uses helpers missing from this Ollama; patching..."
            $parts = $Model.Split(':', 2)
            $modelName = $parts[0]
            $modelTag = if ($parts.Length -eq 2) { $parts[1] } else { "latest" }
            $manifestPath = Join-Path $env:USERPROFILE ".ollama/models/manifests/registry.ollama.ai/library/$modelName/$modelTag"
            if (-not (Test-Path $manifestPath)) {
                Fail "Cannot locate Ollama manifest at $manifestPath. Upgrade Ollama (https://ollama.com/download) and re-run."
            }
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
            $tmplLayer = $manifest.layers | Where-Object { $_.mediaType -eq "application/vnd.ollama.image.template" } | Select-Object -First 1
            if (-not $tmplLayer) { Fail "Could not find template layer in manifest." }
            $tmplDigest = $tmplLayer.digest.Split(':', 2)[1]
            $blobPath = Join-Path $env:USERPROFILE ".ollama/models/blobs/sha256-$tmplDigest"
            if (-not (Test-Path $blobPath)) { Fail "Template blob missing at $blobPath." }
            $today = (Get-Date).ToString("yyyy-MM-dd")
            $yesterday = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
            $tmpl = Get-Content $blobPath -Raw
            $tmpl = $tmpl -replace '{{ *currentDate *}}', $today
            $tmpl = $tmpl -replace '{{ *yesterdayDate *}}', $yesterday
            $tmpModelfile = New-TemporaryFile
            "FROM $Model`nTEMPLATE `"`"`"$tmpl`"`"`"`n" | Set-Content -Path $tmpModelfile -NoNewline
            & ollama create $Model -f $tmpModelfile.FullName | Out-Null
            Remove-Item $tmpModelfile -Force
            Info "Patched template applied to $Model"
        }
    } finally { $env:OLLAMA_HOST = $prev }
    Info "Model '$Model' is ready"
}

# ─── Compose ─────────────────────────────────────────────────────────────────
$profileFlags = @()
if ($useCloud) { $profileFlags += @("--profile", "cloud") }
if ($useMcp)   { $profileFlags += @("--profile", "mcp")   }

Write-Host ""
Write-Host "Pulling container images..."
& docker compose @profileFlags pull --quiet
Write-Host "Starting the stack..."
& docker compose @profileFlags up -d

Write-Host ""
Write-Host "Bootstrapping (one-time; takes ~60s on a warm install)..."
for ($i = 0; $i -lt 120; $i++) {
    $cid = (& docker compose ps -aq stack-init 2>$null) -split "`n" | Select-Object -First 1
    if ($cid) {
        $state = (& docker inspect -f '{{.State.Status}}' $cid 2>$null)
        if ($state -eq "exited") { break }
    }
    Start-Sleep -Seconds 5
}

# ─── Done ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================="
Write-Host "  Setup complete!"
Write-Host ""
Write-Host "  OpenWebUI:  http://localhost:$WebuiPort"
Write-Host "  n8n:        http://localhost:$N8nPort"
Write-Host ""
Write-Host "  Default credentials (n8n + OpenWebUI):"
Write-Host "    email:    student@example.com"
Write-Host "    password: Ai-classroom-2026"
Write-Host ""
Write-Host "  The Summarise URL tool is pre-registered. Open a chat,"
Write-Host "  toggle the tool on in the composer, and try:"
Write-Host "    'summarise https://en.wikipedia.org/wiki/Singapore'"
Write-Host ""
Write-Host "  Re-run this script any time to bring the stack back up."
Write-Host "========================================="
Write-Host ""
