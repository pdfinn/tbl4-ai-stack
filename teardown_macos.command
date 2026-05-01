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
# Only offer to uninstall Ollama if *this* repo's setup installed it.
# Setup drops .tbl4-installed-ollama containing the install path; if the
# marker is absent the user had Ollama from elsewhere (Homebrew, prior
# install, …) and we keep our hands off it.
if [ -f .tbl4-installed-ollama ]; then
    if confirm "Uninstall the Ollama that setup installed (and remove its models)?"; then
        warn "Stop the Ollama menu-bar app first if it's running."
        ollama_bin=$(cat .tbl4-installed-ollama 2>/dev/null || true)
        if [ -n "$ollama_bin" ] && [ -e "$ollama_bin" ]; then
            sudo rm -f "$ollama_bin" || true
        fi
        rm -rf "${HOME}/.ollama" || true
        rm -f .tbl4-installed-ollama
        info "Ollama removed"
    fi
fi

echo
echo "Done."
