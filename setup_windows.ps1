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
# Anchor every path to the script's own folder. Relative paths break when the
# shell's working directory isn't the repo (right-click "Run with PowerShell",
# a shortcut with the wrong Start In, or a wrapper that skipped the cd), and
# Resolve-Path treats [] in a folder name as a wildcard pattern.
$RepoRoot       = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }
$EnvPath        = Join-Path $RepoRoot ".env"
$EnvExamplePath = Join-Path $RepoRoot ".env.example"
Set-Location -LiteralPath $RepoRoot

# All .env I/O goes through the helpers below -- never Get-Content /
# Set-Content / Add-Content, which are the whole reason this section exists.
#
# Windows PowerShell 5.1 decodes a BOM-less file as the ANSI codepage, while
# [IO.File]::WriteAllText encodes UTF-8. The old Set-EnvVar mixed the two, so
# each call re-encoded every non-ASCII byte into a longer sequence: the '---'
# rules in .env.example's comments made the file grow ~2.2x per call, ~5x per
# setup run. A student whose earlier steps failed and who re-ran setup half a
# dozen times ended up with a .env of hundreds of megabytes, and the rewrite
# died with OutOfMemoryException -- on what read like a trivial write of a 2 KB
# file, on a machine with 32 GB free. Read and write UTF-8 explicitly, and
# batch every edit into a single write.

# Reading: strict UTF-8, falling back to ANSI once for a file left behind by an
# older run (or hand-edited in a legacy editor). The write below then converts
# it to UTF-8 for good, so the fallback is a one-time migration, not a cycle.
function Read-EnvText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    try {
        # throwOnInvalidBytes so we can detect ANSI rather than silently
        # substituting U+FFFD all over the student's settings.
        return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
    } catch {
        return [System.Text.Encoding]::Default.GetString($bytes)
    }
}

function Write-EnvText([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# Pull KEY=VALUE pairs out of .env without materialising the file. A .env
# bloated by the old encoding bug is a handful of enormous comment lines, so
# even ReadLine() would allocate one whole and hit the same OutOfMemoryException
# we are here to recover from. Fixed-size blocks with a line-length cap keep
# this bounded at any file size.
function Get-EnvSettings([string]$Path) {
    $settings = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $settings }
    $keyValue = '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*?)\r?$'
    $reader = New-Object System.IO.StreamReader($Path, [System.Text.Encoding]::UTF8, $true)
    try {
        $buf = New-Object char[] 65536
        $partial = ""
        while (($n = $reader.Read($buf, 0, $buf.Length)) -gt 0) {
            $pieces = ($partial + [string]::new($buf, 0, $n)) -split "`n"
            $partial = $pieces[$pieces.Count - 1]
            # Drop a runaway comment line instead of growing with it.
            if ($partial.Length -gt 8192) { $partial = "" }
            if ($pieces.Count -ge 2) {
                foreach ($line in $pieces[0..($pieces.Count - 2)]) {
                    if ($line.Length -le 4096 -and $line -match $keyValue) {
                        $settings[$matches[1]] = $matches[2].Trim()
                    }
                }
            }
        }
        if ($partial.Length -le 4096 -and $partial -match $keyValue) {
            $settings[$matches[1]] = $matches[2].Trim()
        }
    } finally { $reader.Dispose() }
    return $settings
}

# Apply every pending change in one read + one write. Values are assigned as
# plain strings, not via -replace: a value containing '$1' or '$&' would
# otherwise be expanded as a regex backreference and silently corrupt the file.
function Set-EnvVars([hashtable]$Updates) {
    if ($Updates.Count -eq 0) { return }
    $lines = @((Read-EnvText $EnvPath) -split "\r?\n")
    $seen  = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') {
            $key = $matches[1]
            if ($Updates.ContainsKey($key)) {
                $lines[$i] = "$key=$($Updates[$key])"
                $seen[$key] = $true
            }
        }
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) { $out.Add($line) }
    foreach ($key in ($Updates.Keys | Sort-Object)) {
        if (-not $seen.ContainsKey($key)) { $out.Add("$key=$($Updates[$key])") }
    }
    Write-EnvText $EnvPath ((($out -join "`n").TrimEnd("`n")) + "`n")
}

# Heal a .env already wrecked by the pre-fix encoding bug: keep every real
# setting, rebuild the comments from .env.example. Without this, students who
# ran the broken script stay broken no matter how correct the code above is.
function Repair-EnvFile {
    if (-not (Test-Path -LiteralPath $EnvPath)) { return }
    $size = (Get-Item -LiteralPath $EnvPath -Force).Length
    # A sane .env is ~2 KB; 64 KB is generous headroom for a student's edits.
    $bloated = $size -gt 65536
    $garbled = $false
    if (-not $bloated) {
        # UTF-8 read back as CP1252 always yields a high-Latin lead byte
        # (C2/C3/E2) followed by another non-ASCII char. Written as escapes so
        # this script stays pure ASCII and cannot be broken by its own encoding.
        $garbled = (Read-EnvText $EnvPath) -match '[\u00C2\u00C3\u00E2][\u0080-\uFFFF]'
    }
    if (-not ($bloated -or $garbled)) { return }

    $shown = if ($size -gt 1MB) { "{0:N1} MB" -f ($size / 1MB) } else { "$size bytes" }
    Warn "Your .env was damaged by an earlier version of this setup script"
    Warn "(size: $shown). Rebuilding it and keeping your settings..."

    $keep = Get-EnvSettings $EnvPath
    $backup = "$EnvPath.bak"
    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $EnvPath -Destination $backup -Force
    Copy-Item -LiteralPath $EnvExamplePath -Destination $EnvPath -Force
    Set-EnvVars $keep
    if ($size -gt 1MB) {
        # Nothing salvageable left in it and it would sit there eating disk.
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        Info "Rebuilt .env from .env.example (kept $($keep.Count) settings)"
    } else {
        Info "Rebuilt .env from .env.example (kept $($keep.Count) settings; old copy: .env.bak)"
    }
}

try {
    if (-not (Test-Path -LiteralPath $EnvExamplePath)) {
        Fail @"
.env.example is missing from this folder:
  $RepoRoot
The ZIP was probably extracted into a nested folder, or only part of it was
extracted. Open the folder that actually contains docker-compose.yml and
.env.example, and run setup_windows.bat from there.
"@
    }
    if (-not (Test-Path -LiteralPath $EnvPath)) {
        Copy-Item -LiteralPath $EnvExamplePath -Destination $EnvPath -Force
        Info "Created .env from .env.example"
    }
    Repair-EnvFile

    $envVars    = Get-EnvSettings $EnvPath
    $envUpdates = @{}

    # Generate a WEBUI_SECRET_KEY on first run.
    if (-not $envVars.ContainsKey("WEBUI_SECRET_KEY") -or [string]::IsNullOrEmpty($envVars["WEBUI_SECRET_KEY"])) {
        $bytes = New-Object byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $envUpdates["WEBUI_SECRET_KEY"] = ([BitConverter]::ToString($bytes) -replace '-', '').ToLower()
        Info "Generated WEBUI_SECRET_KEY"
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
    $envUpdates["OLLAMA_BASE_URL"] = $ollamaUrl
    $envUpdates["OLLAMA_HOST"]     = $ollamaUrl

    Set-EnvVars $envUpdates
} catch {
    Fail @"
Could not prepare the .env configuration file.
  $($_.Exception.Message)

To recover: delete .env from this folder and run setup again -- it will be
recreated from .env.example.
  Folder: $RepoRoot
"@
}

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

# Capture a native command's stdout and exit code with stderr discarded.
# Same EAP trap as above: '2>$null' counts as redirecting, so under
# $ErrorActionPreference='Stop' a single stderr line (compose's "found orphan
# containers" warning, say) becomes a terminating NativeCommandError.
function Invoke-NativeCapture([scriptblock]$Script) {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $out = & $Script 2>$null
        return [pscustomobject]@{ Output = (($out | Out-String).Trim()); ExitCode = $LASTEXITCODE }
    } catch {
        return [pscustomobject]@{ Output = ""; ExitCode = 1 }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

# IMPORTANT, and the reason several checks below look verbose: an *uncaptured*
# native command never raises a terminating error, not even on a stderr write
# and not even under $ErrorActionPreference='Stop'. So
#     try { winget install ... } catch { Fail "..." }
# can never fire -- the catch is dead code, and the script sails on to announce
# success. Every native call must have its $LASTEXITCODE checked explicitly,
# and every "[OK]" must be earned by verifying the end state rather than by
# reaching a particular line.

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

# Find ollama.exe: PATH first, then the directory winget installs it into.
# The second check matters because winget updates the *registry* PATH, which
# this already-running process does not see -- that gap is what surfaces later
# as "'ollama' is not recognized" long after setup claimed it was installed.
function Get-OllamaPath([string]$InstallDir) {
    $cmd = Get-Command ollama -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = Join-Path $InstallDir "ollama.exe"
    if (Test-Path -LiteralPath $exe) { return $exe }
    return $null
}

if ($useLocal -and -not $useCloud) {
    $ollamaDir = Join-Path $env:LOCALAPPDATA "Programs\Ollama"

    if (-not (Get-OllamaPath $ollamaDir)) {
        Write-Host ""
        Warn "Installing Ollama..."
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Fail @"
Ollama is not installed, and winget is not available on this machine.
Install Ollama manually, then re-run this setup:
  https://ollama.com/download/windows
"@
        }
        winget install --id Ollama.Ollama --accept-source-agreements --accept-package-agreements
        $wingetExit = $LASTEXITCODE

        # Pick up the PATH winget just wrote. Append rather than replace: the
        # old code overwrote $env:PATH with Machine+User and silently dropped
        # anything this process had that the registry does not.
        $machinePath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
        $userPath    = [System.Environment]::GetEnvironmentVariable("PATH", "User")
        $env:PATH = (@($env:PATH, $machinePath, $userPath) | Where-Object { $_ }) -join ";"

        # Verify the install instead of assuming it. winget exits non-zero on a
        # corrupt source cache without throwing, which is how a failed install
        # used to be reported as "[OK] Ollama is installed".
        if (-not (Get-OllamaPath $ollamaDir)) {
            Fail @"
Ollama was not installed (winget exit code $wingetExit).
It is not on PATH, and nothing was installed to:
  $ollamaDir

If winget reported a source or cache error above, repair it with:
  winget source reset --force
Otherwise install Ollama manually and re-run this setup:
  https://ollama.com/download/windows
"@
        }
        if ($wingetExit -ne 0) {
            # Ollama is there despite the non-zero exit (winget reports one for
            # benign cases too, such as "no applicable upgrade"). Worth saying
            # out loud so a later oddity is traceable, but not worth stopping.
            Warn "winget exited $wingetExit, but Ollama is present - continuing."
        }
        # Marker so teardown knows *this script* installed Ollama. Without it,
        # teardown will not touch a host Ollama the user installed separately.
        # Written only after the install is confirmed, so teardown never offers
        # to uninstall something setup failed to install.
        Set-Content -LiteralPath (Join-Path $RepoRoot ".tbl4-installed-ollama") -Value "Ollama.Ollama" -Encoding ASCII
        Write-Host ""
    }

    # Ollama exists, but this shell may still not be able to invoke it.
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        $env:PATH = "$env:PATH;$ollamaDir"
    }
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        Fail @"
Ollama is installed but cannot be run from this window.
Expected to find ollama.exe in:
  $ollamaDir
Close this window, open a new one, and run setup_windows.bat again.
"@
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

# Identify whatever is holding a TCP port. Docker first (it knows which
# container publishes what), then the OS. Process names belonging to Docker
# Desktop's own port relay are reported as 'relay' rather than as something
# the student could usefully close.
$DockerRelayProcesses = @("wslrelay", "com.docker.backend", "com.docker.proxy", "vpnkit", "docker")

function Get-PortHolder([string]$Port) {
    $ps = Invoke-NativeCapture { & docker ps --filter "publish=$Port" --format "{{.Names}}" }
    if ($ps.ExitCode -eq 0 -and $ps.Output) {
        $name = ($ps.Output -split "`n" | Where-Object { $_ } | Select-Object -First 1)
        if ($name) {
            $name = $name.Trim()
            $proj = (Invoke-NativeCapture {
                & docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' $name
            }).Output
            if ($proj -eq "<no value>") { $proj = "" }
            return [pscustomobject]@{ Kind = "container"; Name = $name; Project = $proj.Trim(); ProcessId = $null }
        }
    }
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if ($conn) {
            $procName = (Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            $kind = if ($procName -and ($DockerRelayProcesses -contains $procName)) { "relay" } else { "process" }
            return [pscustomobject]@{ Kind = $kind; Name = $procName; Project = ""; ProcessId = $conn.OwningProcess }
        }
    }
    return $null
}

$profileFlags = @()
if ($useCloud) { $profileFlags += @("--profile", "cloud") }
if ($useMcp)   { $profileFlags += @("--profile", "mcp")   }

# Reap profile-gated containers left running from a prior profile. Switching
# cloud->local would otherwise leave the previous run's ollama container up,
# silently holding RAM (and worse, students would see it in 'docker ps' and
# get confused about which Ollama is actually serving). Pass --profile cloud
# --profile mcp so compose 'sees' the full service graph; `rm -fs` is a
# no-op on services that aren't running, so this is safe on first install.
$reap = @()
if (-not $useCloud) { $reap += @("ollama", "ollama-init") }
if (-not $useMcp)   { $reap += @("mcpo") }
if ($reap.Count -gt 0) {
    Invoke-NativeQuietExit { & docker compose --profile cloud --profile mcp rm -fs @reap } | Out-Null
}

Write-Host ""
Write-Host "Pulling container images..."
& docker compose @profileFlags pull --quiet
if ($LASTEXITCODE -ne 0) {
    Fail @"
Could not download the container images (docker compose pull exited $LASTEXITCODE).
This is almost always a network or Docker Hub problem. Check the error above,
confirm you are online, and re-run this setup.
"@
}

Write-Host "Starting the stack..."
& docker compose @profileFlags up -d
if ($LASTEXITCODE -ne 0) {
    # Overwhelmingly the cause is a port already in use, so name the culprit
    # instead of leaving the student to decode compose's error.
    #
    # Ask Docker before asking Windows. Docker Desktop proxies every published
    # port through its own relay, so the OS reports the owner as 'wslrelay' or
    # 'com.docker.backend' -- which is not something a student can close, and
    # telling them to try is worse than saying nothing. The real holder is
    # usually another container, very often a second copy of this same stack
    # left running from an extracted ZIP in a different folder.
    $busy  = @()
    $steps = @()
    foreach ($port in @($WebuiPort, $N8nPort)) {
        $holder = Get-PortHolder $port
        if (-not $holder) { continue }
        if ($holder.Kind -eq "container") {
            $from = if ($holder.Project) { " (compose project '$($holder.Project)')" } else { "" }
            $busy  += "  port $port is published by the container '$($holder.Name)'$from"
            $steps += "  docker stop $($holder.Name)"
        } elseif ($holder.Kind -eq "relay") {
            $busy  += "  port $port is held by Docker's port relay, so another container has it"
            $steps += "  docker ps --filter publish=$port"
        } else {
            $busy  += "  port $port is already in use by '$($holder.Name)' (PID $($holder.ProcessId))"
            $steps += "  close '$($holder.Name)', or change the port in .env"
        }
    }
    if ($busy.Count -gt 0) {
        Fail @"
The stack did not start (docker compose up exited $LASTEXITCODE).

$($busy -join "`n")

To fix it, either free the port:
$(($steps | Select-Object -Unique) -join "`n")

or change WEBUI_PORT / N8N_PORT in .env and re-run this setup.
"@
    }
    Fail @"
The stack did not start (docker compose up exited $LASTEXITCODE).
Read the error above, then re-run this setup. To see the full detail:
  docker compose logs
"@
}

# 'compose up' exiting 0 does not mean the stack is usable. If an earlier run
# failed partway -- a port clash, say -- the containers already exist with no
# network and no port bindings, and starting those "succeeds". Observed for
# real: n8n and open-webui came up healthy, attached to no network, publishing
# nothing, so stack-init sat for 20 minutes unable to resolve its peers, while
# localhost:3000 happily served a *different* copy of this stack that did hold
# the port. Verify the ports are actually bound before trusting the run.
$expectedPorts = @(
    @{ Service = "open-webui"; ContainerPort = 8080; HostPort = $WebuiPort }
    @{ Service = "n8n";        ContainerPort = 5678; HostPort = $N8nPort   }
)
$unbound = @()
foreach ($expected in $expectedPorts) {
    $bound = Invoke-NativeCapture { & docker compose port $expected.Service $expected.ContainerPort }
    if ($bound.ExitCode -ne 0 -or $bound.Output -notmatch ":$($expected.HostPort)\s*$") {
        $unbound += $expected
    }
}
if ($unbound.Count -gt 0) {
    $lines = @()
    foreach ($expected in $unbound) {
        $holder = Get-PortHolder $expected.HostPort
        if ($holder -and $holder.Kind -eq "container") {
            $from = if ($holder.Project) { " (compose project '$($holder.Project)')" } else { "" }
            $lines += "  $($expected.Service): port $($expected.HostPort) is not bound - '$($holder.Name)'$from has it"
        } else {
            $lines += "  $($expected.Service): port $($expected.HostPort) is not bound"
        }
    }
    Fail @"
The containers started, but the stack is not reachable on its ports:

$($lines -join "`n")

This happens when an earlier run failed partway and left containers behind, or
when another copy of this stack already holds these ports. Clear this project's
containers:
  docker compose down

Then free the port (or change WEBUI_PORT / N8N_PORT in .env) and re-run setup.
"@
}

Write-Host ""
Write-Host "Bootstrapping (one-time; takes ~60s on a warm install)..."
# On cloud profile, ollama-init pulls the model inside the container; we
# can't claim "Setup complete!" until that's actually done, or the first
# chat 404s with "model not found".
$initServices = @("stack-init")
if ($useCloud) { $initServices += "ollama-init" }
foreach ($svc in $initServices) {
    $state    = $null
    $exitCode = $null
    for ($i = 0; $i -lt 240; $i++) {
        $cid = ((Invoke-NativeCapture { & docker compose ps -aq $svc }).Output -split "`n" |
                Select-Object -First 1).Trim()
        if ($cid) {
            $state = (Invoke-NativeCapture { & docker inspect -f '{{.State.Status}}' $cid }).Output
            if ($state -eq "exited") {
                $exitCode = (Invoke-NativeCapture { & docker inspect -f '{{.State.ExitCode}}' $cid }).Output
                break
            }
        } elseif ($i -ge 6) {
            # 30 seconds in and compose still reports no container for this
            # service: it is never going to appear. The old loop sat here for
            # the full 20 minutes and then printed "Setup complete!".
            Fail @"
The '$svc' bootstrap container never started.
See what compose thinks is running:
  docker compose ps -a
  docker compose logs $svc
"@
        }
        Start-Sleep -Seconds 5
    }
    if ($state -ne "exited") {
        Fail @"
The '$svc' bootstrap container did not finish within 20 minutes.
Check its progress with:
  docker compose logs $svc
"@
    }
    # A container that exited is not a container that succeeded.
    if ($exitCode -ne "0") {
        Fail @"
Bootstrapping failed: '$svc' exited with code $exitCode.
The containers are running but the stack is not fully configured, so the
web UIs will not behave correctly yet. See what went wrong with:
  docker compose logs $svc
"@
    }
    Info "$svc finished"
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
