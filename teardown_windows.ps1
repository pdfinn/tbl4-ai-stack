# ─── tbl4-stack Teardown (Windows) ──────────────────────────────────────────
# Stops the stack and (optionally) deletes its volumes and host Ollama.
# Asks for confirmation before each destructive step.
#
# Students: just double-click teardown_windows.bat in File Explorer.

$ErrorActionPreference = "Stop"

function Info($msg)  { Write-Host "[OK]  $msg" -ForegroundColor Green }
function Warn($msg)  { Write-Host "[!!]  $msg" -ForegroundColor Yellow }
function Skip($msg)  { Write-Host "[--]  Skipped: $msg" -ForegroundColor Yellow }

function Confirm-Step($message) {
    Write-Host ""
    Write-Host $message -ForegroundColor Yellow
    $answer = Read-Host "Proceed? (y/N)"
    return ($answer -eq "y" -or $answer -eq "Y" -or $answer -eq "yes")
}

Write-Host ""
Write-Host "========================================="
Write-Host "  Tarkas Brainlab IV — Stack Teardown"
Write-Host "========================================="
Write-Host ""

# ─── Step 1: Stop containers (all profiles) ─────────────────────────────────
Write-Host "Stopping containers..."
& docker compose --profile cloud --profile mcp down
Info "Containers stopped"

# ─── Step 2: Delete volumes ──────────────────────────────────────────────────
if (Confirm-Step "Delete tbl4-stack volumes (chat history, n8n workflows, OpenWebUI tools)?") {
    & docker compose --profile cloud --profile mcp down -v
    Info "Volumes deleted"
} else {
    Skip "tbl4-stack volumes"
}

# ─── Step 3: Uninstall Ollama (host) ─────────────────────────────────────────
$ollamaInstalled = $false
try { $null = Get-Command ollama -ErrorAction Stop; $ollamaInstalled = $true } catch {}

if ($ollamaInstalled) {
    if (Confirm-Step "Uninstall Ollama from your system?") {
        try { Stop-Process -Name "ollama*" -Force -ErrorAction SilentlyContinue } catch {}
        try {
            winget uninstall --id Ollama.Ollama --accept-source-agreements
            Info "Ollama uninstalled"
        } catch {
            Warn "Could not auto-uninstall Ollama. Remove it from Settings > Apps > Installed apps."
        }
    } else {
        Skip "Ollama uninstall"
    }
}

Write-Host ""
Write-Host "========================================="
Write-Host "  Teardown complete."
Write-Host ""
Write-Host "  If you also want to remove Docker Desktop"
Write-Host "  itself, do that from Settings > Apps."
Write-Host "========================================="
Write-Host ""
