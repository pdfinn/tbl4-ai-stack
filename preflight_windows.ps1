# --- tbl4-ai-stack Preflight (Windows) ---------------------------------------
# One-shot fixer for the two issues that block most Windows installs:
#   * WSL2 missing / out of date
#   * required Windows features not enabled
# It also reports (but cannot fix) firmware virtualization, RAM and disk.
#
# Students: right-click preflight_windows.bat -> "Run as administrator".
# This file is the internal script that wrapper calls.

$ErrorActionPreference = "Stop"

function Info($msg) { Write-Host "[OK]  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[!!]  $msg" -ForegroundColor Yellow }
function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# --- Elevate -----------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Re-launching as Administrator (approve the UAC prompt)..."
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    exit
}

Write-Host ""
Write-Host "========================================="
Write-Host "  Tarkas Brainlab IV - Windows Preflight"
Write-Host "========================================="

$rebootNeeded = $false

# --- Windows features --------------------------------------------------------
# Docker Desktop's WSL2 backend needs these two. Enabling is idempotent.
Step "Windows features (WSL + Virtual Machine Platform)"
foreach ($feature in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
    try {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
        if ($state -eq 'Enabled') {
            Info "$feature already enabled"
        } else {
            Warn "$feature is $state - enabling..."
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
            Info "$feature enabled"
            if ($result.RestartNeeded) { $rebootNeeded = $true }
        }
    } catch {
        Warn "Could not query/enable ${feature}: $($_.Exception.Message)"
    }
}

# --- WSL2 --------------------------------------------------------------------
# Native commands are called uncaptured and checked via $LASTEXITCODE. An
# uncaptured native command never raises a terminating error, so a try/catch
# around one cannot report its failure -- which is how a failed 'wsl --update'
# used to still print "[OK] WSL updated".
Step "WSL2 kernel"
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wsl) {
    Warn "wsl.exe not found - installing WSL (this may require a reboot)..."
    & wsl.exe --install --no-distribution
    if ($LASTEXITCODE -ne 0) {
        Warn "wsl --install exited $LASTEXITCODE. If it did not complete, open an"
        Warn "Administrator PowerShell and run 'wsl --install' by hand."
    }
    $rebootNeeded = $true
} else {
    Warn "Updating WSL kernel (wsl --update)..."
    & wsl.exe --update
    $updateExit = $LASTEXITCODE
    & wsl.exe --set-default-version 2 | Out-Null
    $versionExit = $LASTEXITCODE
    if ($updateExit -ne 0) {
        Warn "wsl --update exited $updateExit - the kernel may be out of date."
        Warn "If Docker Desktop will not start, run 'wsl --update' as Administrator."
    } elseif ($versionExit -ne 0) {
        Warn "wsl --set-default-version 2 exited $versionExit - WSL1 may still be the default."
    } else {
        Info "WSL updated; default version set to 2"
    }
}

# --- Virtualization in firmware (report only) --------------------------------
Step "Hardware virtualization"
try {
    $cs  = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ($cs.HypervisorPresent) {
        Info "A hypervisor is running - virtualization is active"
    } elseif ($cpu.VirtualizationFirmwareEnabled -eq $false) {
        Warn "Virtualization is DISABLED in firmware (BIOS/UEFI)."
        Warn "This CANNOT be fixed from Windows. Reboot into BIOS/UEFI and enable:"
        Warn "   Intel: 'Intel VT-x' / 'Virtualization Technology'"
        Warn "   AMD:   'SVM Mode' / 'AMD-V'"
    } else {
        Info "Virtualization enabled in firmware"
    }
} catch {
    Warn "Could not read virtualization status."
}

# --- RAM + disk (report only) ------------------------------------------------
Step "RAM and disk"
try {
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    if ($ramGB -lt 8) {
        Warn "RAM: ${ramGB} GB - under 8 GB. Keep PROFILES=local and a small MODEL (llama3.2)."
    } else {
        Info "RAM: ${ramGB} GB"
    }
} catch { Warn "Could not read RAM." }
try {
    $sys = $env:SystemDrive
    $free = [math]::Round((Get-PSDrive ($sys.TrimEnd(':'))).Free / 1GB, 1)
    if ($free -lt 20) {
        Warn "Free space on ${sys} ${free} GB - under 20 GB. Free some space before installing."
    } else {
        Info "Free space on ${sys} ${free} GB"
    }
} catch { Warn "Could not read disk space." }

# --- Done --------------------------------------------------------------------
Write-Host ""
Write-Host "========================================="
if ($rebootNeeded) {
    Warn "A REBOOT is required to finish enabling Windows features."
    Warn "Reboot, then run setup_windows.bat."
} else {
    Info "Preflight complete. Run setup_windows.bat to start the stack."
}
Write-Host "========================================="
Write-Host ""
Read-Host "Press Enter to close"
