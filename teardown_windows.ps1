# --- tbl4-ai-stack Teardown (Windows) ------------------------------------------
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
Write-Host "  Tarkas Brainlab IV - Stack Teardown"
Write-Host "========================================="
Write-Host ""

# An uncaptured native command never raises a terminating error -- not even on
# a stderr write, and not even under $ErrorActionPreference='Stop'. So a
# try/catch around one is dead code, and the only honest signal is
# $LASTEXITCODE. Every "[OK]" below is conditional on it.

# --- Step 1: Stop containers (all profiles) ---------------------------------
Write-Host "Stopping containers..."
& docker compose --profile cloud --profile mcp down
if ($LASTEXITCODE -ne 0) {
    Warn "docker compose down exited $LASTEXITCODE - some containers may still be running."
    Warn "Check with: docker compose ps -a"
} else {
    Info "Containers stopped"
}

# --- Step 2: Delete volumes --------------------------------------------------
if (Confirm-Step "Delete tbl4-ai-stack state (volumes + local .env: chat history, workflows, tools, custom settings)?") {
    & docker compose --profile cloud --profile mcp down -v
    Info "Volumes deleted"
    # Drop .env too: setup only writes it on first run, so a stale .env
    # from a prior testing session silently survives teardown and pins
    # the next setup to non-default ports / secrets.
    Remove-Item -Path .env -Force -ErrorAction SilentlyContinue
    Info ".env removed"
} else {
    Skip "tbl4-ai-stack state"
}

# --- Step 3: Uninstall Ollama (host, only if setup installed it) -------------
# Only offer to uninstall Ollama if *this* repo's setup installed it.
# Setup drops .tbl4-installed-ollama; if the marker is absent the user had
# Ollama from elsewhere (winget/manual install before running setup) and we
# keep our hands off it.
if (Test-Path .tbl4-installed-ollama) {
    if (Confirm-Step "Uninstall the Ollama that setup installed (and remove its models)?") {
        try { Stop-Process -Name "ollama*" -Force -ErrorAction SilentlyContinue } catch {}
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Warn "winget is not available. Remove Ollama from Settings > Apps > Installed apps."
        } else {
            winget uninstall --id Ollama.Ollama --accept-source-agreements
            if ($LASTEXITCODE -eq 0) {
                Remove-Item -Path .tbl4-installed-ollama -Force -ErrorAction SilentlyContinue
                Info "Ollama uninstalled"
            } else {
                # Keep the marker: the uninstall did not happen, so a later
                # teardown should still offer to retry it.
                Warn "Could not uninstall Ollama (winget exit code $LASTEXITCODE)."
                Warn "Remove it from Settings > Apps > Installed apps."
            }
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
