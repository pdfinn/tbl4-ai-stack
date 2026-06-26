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
Step "WSL2 kernel"
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wsl) {
    Warn "wsl.exe not found - installing WSL (this may require a reboot)..."
    try { & wsl.exe --install --no-distribution 2>&1 | Write-Host } catch {}
    $rebootNeeded = $true
} else {
    Warn "Updating WSL kernel (wsl --update)..."
    try { & wsl.exe --update 2>&1 | Write-Host } catch {}
    try { & wsl.exe --set-default-version 2 2>&1 | Out-Null } catch {}
    Info "WSL updated; default version set to 2"
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
