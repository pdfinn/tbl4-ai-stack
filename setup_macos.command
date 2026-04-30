#!/usr/bin/env bash
set -euo pipefail

# ─── tbl4-ai-stack setup (macOS) ───────────────────────────────────────────────
# Brings up the unified classroom stack: OpenWebUI + n8n + auto-bootstrapper
# and (optionally) containerised Ollama and the mcpo MCP proxy.
#
# Profiles are driven by the PROFILES line in .env (comma-separated):
#   local — Ollama runs on the host (default; uses GPU/Metal)
#   cloud — Ollama runs as a container in the stack
#   mcp   — adds the mcpo proxy
# Combine freely, e.g. PROFILES=cloud,mcp
#
# Safe to run multiple times.

# Finder launches .command files with $HOME as cwd; jump to the script's dir.
cd "$(dirname "${BASH_SOURCE[0]}")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[!!]${NC}  $1"; }
fail()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

echo
echo "========================================="
echo "  Tarkas Brainlab IV — Stack Setup"
echo "========================================="
echo

# ─── .env ──────────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
    cp .env.example .env
    info "Created .env from .env.example"
fi

# Generate WEBUI_SECRET_KEY on first run.
if ! grep -Eq '^WEBUI_SECRET_KEY=.+' .env; then
    SECRET=$(openssl rand -hex 32)
    if grep -q '^WEBUI_SECRET_KEY=' .env; then
        sed -i '' "s|^WEBUI_SECRET_KEY=.*|WEBUI_SECRET_KEY=${SECRET}|" .env
    else
        printf '\nWEBUI_SECRET_KEY=%s\n' "${SECRET}" >> .env
    fi
    info "Generated WEBUI_SECRET_KEY"
fi

# Read configuration. We deliberately do NOT export these values: docker
# compose reads .env on its own, and exporting OLLAMA_HOST would shadow the
# host Ollama CLI's default (it honours that env var as the server URL).
source .env

PROFILES="${PROFILES:-local}"
MODEL="${MODEL:-mistral}"
WEBUI_PORT="${WEBUI_PORT:-3000}"
N8N_PORT="${N8N_PORT:-5678}"

# Profile detection (case-insensitive substring)
profiles_lc=$(echo ",$PROFILES," | tr '[:upper:]' '[:lower:]')
case "$profiles_lc" in *,cloud,*) USE_CLOUD=1 ;; *) USE_CLOUD=0 ;; esac
case "$profiles_lc" in *,mcp,*)   USE_MCP=1   ;; *) USE_MCP=0   ;; esac
# Local is the default; only matters for whether we install/start host Ollama.
case "$profiles_lc" in *,local,*) USE_LOCAL=1 ;; *) USE_LOCAL=$([ "$USE_CLOUD" = "1" ] && echo 0 || echo 1) ;; esac

info "Profiles: $PROFILES"

# Set the Ollama URL according to profile, and write back to .env so future
# runs (and docker compose) see a consistent value.
if [ "$USE_CLOUD" = "1" ]; then
    OLLAMA_BASE_URL="http://ollama:11434"
else
    OLLAMA_BASE_URL="http://host.docker.internal:11434"
fi
OLLAMA_HOST="$OLLAMA_BASE_URL"
for var in OLLAMA_BASE_URL OLLAMA_HOST; do
    if grep -q "^${var}=" .env; then
        sed -i '' "s|^${var}=.*|${var}=${!var}|" .env
    else
        printf '%s=%s\n' "$var" "${!var}" >> .env
    fi
done

# ─── Docker ────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    fail "Docker is not installed. Install Docker Desktop:
    https://www.docker.com/products/docker-desktop/"
fi
if ! docker info &>/dev/null; then
    fail "Docker is not running. Open Docker Desktop and try again."
fi
info "Docker is running"

# ─── Host Ollama (local profile only) ──────────────────────────────────────
if [ "$USE_LOCAL" = "1" ] && [ "$USE_CLOUD" = "0" ]; then
    if ! command -v ollama &>/dev/null; then
        echo
        warn "Installing Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
        echo
    fi
    info "Ollama is installed"

    if ! curl -sf http://localhost:11434/api/tags &>/dev/null; then
        warn "Starting Ollama..."
        ollama serve &>/dev/null &
        for i in {1..30}; do
            curl -sf http://localhost:11434/api/tags &>/dev/null && break
            sleep 1
        done
        curl -sf http://localhost:11434/api/tags &>/dev/null \
            || fail "Ollama failed to start. Try 'ollama serve' manually."
    fi
    info "Ollama is running"

    echo
    echo "Pulling model: ${MODEL} (first time can take a few minutes)"
    ollama pull "${MODEL}"
    info "Model '${MODEL}' is ready"
fi

# ─── Compose flags ─────────────────────────────────────────────────────────
PROFILE_FLAGS=()
[ "$USE_CLOUD" = "1" ] && PROFILE_FLAGS+=(--profile cloud)
[ "$USE_MCP"   = "1" ] && PROFILE_FLAGS+=(--profile mcp)

# ─── Up ────────────────────────────────────────────────────────────────────
# Empty arrays + set -u don't mix; wrap so docker compose isn't passed an
# empty string as a positional arg.
compose() {
    if [ "${#PROFILE_FLAGS[@]}" -gt 0 ]; then
        docker compose "${PROFILE_FLAGS[@]}" "$@"
    else
        docker compose "$@"
    fi
}

echo
echo "Pulling container images..."
compose pull --quiet
echo "Starting the stack..."
compose up -d

# Wait for stack-init: it's the signal that the first-run bootstrap is done.
echo
echo "Bootstrapping (one-time; takes ~60s on a warm install)..."
for i in {1..120}; do
    state=$(docker inspect -f '{{.State.Status}}' "$(docker compose ps -aq stack-init 2>/dev/null)" 2>/dev/null || echo "missing")
    [ "$state" = "exited" ] && break
    sleep 5
done

# ─── Done ──────────────────────────────────────────────────────────────────
echo
echo "========================================="
echo "  Setup complete!"
echo
echo "  OpenWebUI:  http://localhost:${WEBUI_PORT}"
echo "  n8n:        http://localhost:${N8N_PORT}"
echo
echo "  Default credentials (n8n + OpenWebUI):"
echo "    email:    student@example.com"
echo "    password: Ai-classroom-2026"
echo
echo "  The Summarise URL tool is pre-registered. Open a chat,"
echo "  toggle the tool on in the composer, and try:"
echo "    'summarise https://en.wikipedia.org/wiki/Singapore'"
echo
echo "  Re-run this script any time to bring the stack back up."
echo "========================================="
echo
