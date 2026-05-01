#!/usr/bin/env bash
set -euo pipefail

# ─── tbl4-ai-stack teardown (macOS) ────────────────────────────────────────────
# Stops the stack and (optionally) deletes its volumes and host Ollama.
# Asks for confirmation before each destructive step.

cd "$(dirname "${BASH_SOURCE[0]}")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[!!]${NC}  $1"; }

confirm() {
    read -r -p "$1 [y/N] " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

echo
echo "========================================="
echo "  Tarkas Brainlab IV — Stack Teardown"
echo "========================================="
echo

# Stop containers across all profiles (compose silently no-ops on profiles
# whose services aren't running).
echo "Stopping containers..."
docker compose --profile cloud --profile mcp down
info "Containers stopped"

echo
if confirm "Delete tbl4-ai-stack state (volumes + local .env: chat history, workflows, tools, custom settings)?"; then
    docker compose --profile cloud --profile mcp down -v
    info "Volumes deleted"
    # Drop .env too: setup only writes it on first run, so a stale .env
    # from a prior testing session silently survives teardown and pins
    # the next setup to non-default ports / secrets.
    rm -f .env
    info ".env removed"
fi

echo
if command -v ollama &>/dev/null; then
    if confirm "Uninstall host Ollama and remove its models?"; then
        warn "Stop the Ollama menu-bar app first if it's running."
        sudo rm -f /usr/local/bin/ollama || true
        rm -rf "${HOME}/.ollama" || true
        info "Ollama removed"
    fi
fi

echo
echo "Done."
