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

$ErrorActionPreference = "Stop"

function Info($msg)  { Write-Host "[OK]  $msg" -ForegroundColor Green }
function Warn($msg)  { Write-Host "[!!]  $msg" -ForegroundColor Yellow }
function Fail($msg)  { Write-Host "[ERR] $msg" -ForegroundColor Red; exit 1 }

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

# ─── Docker ──────────────────────────────────────────────────────────────────
try { $null = Get-Command docker -ErrorAction Stop }
catch { Fail "Docker is not installed. Install Docker Desktop:`nhttps://www.docker.com/products/docker-desktop/" }

try { $null = docker info 2>&1 }
catch { Fail "Docker is not running. Start Docker Desktop and try again." }
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
    try { & ollama pull $Model } finally { $env:OLLAMA_HOST = $prev }
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
Write-Host "    email:    tbl4@example.com"
Write-Host "    password: Tbl4-classroom-2026!"
Write-Host ""
Write-Host "  The Summarise URL tool is pre-registered. Open a chat,"
Write-Host "  toggle the tool on in the composer, and try:"
Write-Host "    'summarise https://en.wikipedia.org/wiki/Singapore'"
Write-Host ""
Write-Host "  Re-run this script any time to bring the stack back up."
Write-Host "========================================="
Write-Host ""
