# --- tbl4-ai-stack Setup (Windows) ---------------------------------------------
# Brings up the unified classroom stack: OpenWebUI + n8n + auto-bootstrapper
# and (optionally) containerised Ollama and the mcpo MCP proxy.
#
# Profiles are driven by the PROFILES line in .env (comma-separated):
#   local - Ollama runs on the host (default; uses GPU)
#   cloud - Ollama runs as a container in the stack
#   mcp   - adds the mcpo proxy
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
Write-Host "  Tarkas Brainlab IV - Stack Setup"
Write-Host "========================================="
Write-Host ""

# --- .env --------------------------------------------------------------------
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
$Model     = if ($envVars["MODEL"])      { $envVars["MODEL"]      } else { "llama3.2" }
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

# --- Docker ------------------------------------------------------------------
try { $null = Get-Command docker -ErrorAction Stop }
catch { Fail "Docker is not installed. Install Docker Desktop:`nhttps://www.docker.com/products/docker-desktop/" }

# Run a native command with all streams discarded; return its exit code.
# Under $ErrorActionPreference='Stop', any stderr write from a native exe
# becomes a terminating NativeCommandError -- even `2>$null` does not
# suppress that. Lower EAP for the call so we get the exit code instead
# of an abort. (This was the red "request returned 500..." wall for
# 'docker info' when the engine was down; same trap kills 'ollama show'
# when a model isn't pulled.)
function Invoke-NativeQuietExit([scriptblock]$Script) {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & $Script 2>&1 | Out-Null
        return $LASTEXITCODE
    } catch {
        return 1
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

function Test-DockerUp { return (Invoke-NativeQuietExit { & docker info }) -eq 0 }

# Diagnose the usual Windows blockers (virtualization off in firmware,
# WSL2 missing or stale) and self-heal what is safe to. Returns nothing;
# prints guidance. Never reboots or changes BIOS - it can't.
function Show-DockerHelp {
    Write-Host ""
    Warn "Docker's engine isn't responding. On Windows this is almost always"
    Warn "WSL2 or hardware virtualization. Checking..."
    Write-Host ""

    # 1) Virtualization enabled in firmware (BIOS/UEFI)?
    #    If a hypervisor is already present, virtualization is effectively on
    #    even when the firmware flag reads False (Hyper-V owns it).
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cs.HypervisorPresent) {
            Info "Virtualization: a hypervisor is running (OK)"
        } elseif ($cpu.VirtualizationFirmwareEnabled -eq $false) {
            Fail @"
Virtualization is DISABLED in your firmware (BIOS/UEFI).
Docker Desktop cannot run until you turn it on:
  1. Reboot and enter BIOS/UEFI setup (usually F2, F10, DEL, or ESC at boot).
  2. Enable the CPU virtualization feature:
       Intel:  'Intel VT-x' / 'Virtualization Technology'
       AMD:    'SVM Mode' / 'AMD-V'
  3. Save, reboot, then re-run this setup.
Verify later with:  systeminfo  (look for 'Virtualization Enabled In Firmware: Yes')
"@
        } else {
            Info "Virtualization: enabled in firmware (OK)"
        }
    } catch {
        Warn "Could not read virtualization status; continuing."
    }

    # 2) WSL2: update the kernel (safe, no reboot) and pin default version 2.
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {
        Fail @"
WSL is not installed. Open PowerShell as Administrator and run:
  wsl --install
Reboot, then re-run this setup. (This also enables the required
Windows features: Virtual Machine Platform and WSL.)
"@
    } else {
        Warn "Updating the WSL2 kernel (wsl --update)..."
        try { & wsl.exe --update 2>&1 | Out-Null } catch {}
        try { & wsl.exe --set-default-version 2 2>&1 | Out-Null } catch {}
        Info "WSL2 kernel updated and default version set to 2"
    }

    Write-Host ""
    Warn "If virtualization and WSL2 look OK above, the engine may just need a"
    Warn "moment: open Docker Desktop, wait for the whale to stop animating,"
    Warn "then re-run this setup. For a full one-shot fixer, run"
    Warn "preflight_windows.bat (right-click -> Run as administrator)."
}

if (-not (Test-DockerUp)) {
    $dockerExe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerExe) {
        Warn "Docker is not running. Starting Docker Desktop..."
        Start-Process -FilePath $dockerExe | Out-Null
        # Docker Desktop can take 30-60s to come up on first launch.
        for ($i = 0; $i -lt 90; $i++) {
            if (Test-DockerUp) { break }
            Start-Sleep -Seconds 2
        }
        if (-not (Test-DockerUp)) {
            Show-DockerHelp
            Fail "Docker Desktop didn't become ready within 3 minutes. Resolve the items above and re-run."
        }
    } else {
        Fail "Docker is not running and Docker Desktop is not installed at '$dockerExe'. Install Docker Desktop:`nhttps://www.docker.com/products/docker-desktop/"
    }
}
Info "Docker is running"

# --- Host Ollama (local profile only) ----------------------------------------
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
        if ($LASTEXITCODE -ne 0) {
            Fail "ollama pull '$Model' failed (exit $LASTEXITCODE). Check the network and re-run setup."
        }

        # Some Mistral library templates (e.g. ministral-3:3b) call template
        # helpers - currentDate, yesterdayDate - that older Ollama builds
        # don't define, breaking every chat. If the local Ollama can't
        # render the template, rebuild the model under the same tag with
        # those references substituted out. Run via Invoke-NativeQuietExit
        # so a "model not found" stderr line (e.g. after an aborted pull)
        # doesn't abort this script via NativeCommandError.
        $showExit = Invoke-NativeQuietExit { & ollama show --template $Model }
        if ($showExit -ne 0) {
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
            # Set-Content's PS 5.1 default is UTF-16 LE with BOM; ollama
            # rejects that. WriteAllText is UTF-8 without BOM by default.
            [System.IO.File]::WriteAllText($tmpModelfile.FullName, "FROM $Model`nTEMPLATE `"`"`"$tmpl`"`"`"`n")
            $createExit = Invoke-NativeQuietExit { & ollama create $Model -f $tmpModelfile.FullName }
            Remove-Item $tmpModelfile -Force
            if ($createExit -ne 0) {
                Fail "ollama create '$Model' failed (exit $createExit). Template patch did not apply."
            }
            Info "Patched template applied to $Model"
        }
    } finally { $env:OLLAMA_HOST = $prev }
    Info "Model '$Model' is ready"
}

# --- Compose -----------------------------------------------------------------
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

# --- Done --------------------------------------------------------------------
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
