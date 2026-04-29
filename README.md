<p align="center">
  <img src="logo.png" alt="Tarkas Brainlab IV" width="200">
</p>

<h1 align="center">Tarkas Brainlab IV — AI Stack</h1>

<p align="center">
  Unified classroom stack: local LLM, OpenWebUI, n8n, and tools — one <code>docker compose up</code>.<br>
  Runs locally or in the cloud from the same configuration. Zero clicks to a working chain.
</p>

---

## What you get

After one setup script you have:

- **[OpenWebUI](https://github.com/open-webui/open-webui)** at `http://localhost:3000` — ChatGPT-style chat interface
- **[n8n](https://n8n.io)** at `http://localhost:5678` — visual workflow builder, pre-loaded with two starter workflows
- **[Ollama](https://ollama.com)** — runs the LLM (on the host with GPU/Metal acceleration, or as a container for cloud deploys)
- A **Summarise URL** tool already registered in OpenWebUI and wired to a published n8n webhook

No login pages, no manual import, no copy-paste. Open a chat, toggle the tool on, and ask:

> *summarise https://en.wikipedia.org/wiki/Singapore*

## How this differs from the other tbl4 repos

This repo is the everything-in-one path. The two single-purpose stacks remain available if that's all you need:

- [`tbl4-local-llm`](https://github.com/pdfinn/tbl4-local-llm) — just OpenWebUI + Ollama, no n8n
- [`tbl4-n8n`](https://github.com/pdfinn/tbl4-n8n) — just n8n with classroom workflows

`tbl4-ai-stack` brings them together behind a single compose file, automates first-run bootstrapping, and adds a cloud-deployable profile.

## Prerequisites

- **Docker Desktop** — [download](https://www.docker.com/products/docker-desktop/). Run the installer; on Windows allow the WSL 2 prompt and reboot when asked.

The setup script handles everything else, including installing Ollama on local-profile installs.

## Setup

1. [Download as a ZIP](https://github.com/pdfinn/tbl4-ai-stack/archive/refs/heads/main.zip) and unzip it.
2. Double-click the file for your operating system:
   - **macOS:** `setup_macos.command`
   - **Windows:** `setup_windows.bat`

The first run takes about a minute on warm hardware (downloading container images and the model). Re-runs take seconds.

> **macOS first launch:** Gatekeeper may block the file. Right-click `setup_macos.command` → **Open** → **Open** to approve it once. You may also be asked for your password — that's the Ollama installer adding the `ollama` command.

When the script finishes, open **http://localhost:3000**. The Summarise URL tool is in the composer toolbar; toggle it on and chat normally.

## Deployment profiles

The stack runs in three modes, configured by the `PROFILES` line in `.env`:

| `PROFILES=` | What it does | When to use it |
|-------------|--------------|----------------|
| `local` (default) | Ollama runs on the host machine | Laptop / desktop with a GPU or Apple Silicon |
| `cloud` | Ollama runs as a container alongside the rest | Cloud VM, GPU-less host, fleet deploy |
| `mcp` | Adds the [mcpo](https://github.com/open-webui/mcpo) MCP→OpenAPI proxy | Bringing external MCP servers into OpenWebUI |

Profiles compose. `PROFILES=cloud,mcp` runs the full thing in a container.

After editing `PROFILES` in `.env`, re-run the setup script — it picks up the change, swaps the Ollama URL, and brings the right services up.

## Choosing a model

Edit the `MODEL` line in `.env`, then re-run setup. Browse models at [ollama.com/library](https://ollama.com/library).

| Model | Size | Notes |
|-------|------|-------|
| `ministral-3:3b` | 3B | Default. Apache 2.0, native tool calling. Fits 8GB RAM. |
| `mistral` | 7B | Larger Mistral sibling. More headroom for nuance, needs 16GB to be comfortable. |
| `llama3.1:8b` | 8B | Alternative 8B with reliable tool calling. |
| `gpt-oss:20b` | 20B | Better tool calling on capable machines (32GB+). |

## Stop and restart

Re-run the setup script any time — it's idempotent and will bring everything back up.

To free RAM without uninstalling, just quit Docker Desktop. Host Ollama keeps running in the background and uses very little memory when idle. Next session, re-run the setup.

<details>
<summary>From the command line</summary>

```bash
# Stop
docker compose --profile cloud --profile mcp down

# Start (substitute your active profiles)
docker compose up -d                          # local
docker compose --profile cloud up -d          # cloud
docker compose --profile cloud --profile mcp up -d   # cloud + mcp
```

</details>

## Uninstalling

Run the teardown script for your OS. It asks before each destructive step — nothing is deleted without your approval.

- **macOS:** `teardown_macos.command`
- **Windows:** `teardown_windows.bat`

## Adding more tools

The shipping setup includes one tool (`summarise_url`) wired through n8n's `Summarise URL` workflow. To add more:

1. Build a worker workflow in n8n (Webhook trigger → do work → Respond to Webhook). Publish it.
2. Either:
   - **Python tool** — write a small Python file in the OpenWebUI Tools editor that POSTs to the webhook (see `openwebui-tools/summarise_url.py` as a template), **or**
   - **MCP Tools workflow** — add an HTTP Request Tool node to the seeded `MCP Tools` workflow and re-publish; once OpenWebUI's MCP client bug is fixed, the tool appears automatically.

The pre-seeded `MCP Tools` workflow is the eventual zero-click path; the Python tool is the path that works today.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Docker is not running" | Open Docker Desktop and wait for it to finish starting |
| OpenWebUI shows "Ollama not reachable" (local profile) | `ollama serve`, or just re-run the setup script |
| Summary returns empty body | The model name in `.env` doesn't match a tag on Ollama. `ollama list` to check; pull the right tag or change `MODEL`. |
| Port 3000 / 5678 already in use | Edit `WEBUI_PORT` / `N8N_PORT` in `.env`, re-run setup |
| First launch shows a blank OpenWebUI page | Wait ~60s — it downloads HuggingFace assets on first start |
| Want a clean slate | Run the teardown script and answer "y" to volume removal, then re-run setup |
| macOS: setup file blocked by Gatekeeper | Right-click `setup_macos.command` → **Open** → **Open** (one-time approval) |
| Running on a MacBook Neo (8GB RAM, A18 Pro) | The default `ministral-3:3b` fits. Avoid `mistral` / `llama3.1:8b` — they swap heavily. Stick to the local profile (containerised Ollama on Neo loses Metal acceleration). |

## License

Copyright (c) 2026 Tarkas Brainlab IV (TBL4).

Licensed under the [PolyForm Noncommercial License 1.0.0](./LICENSE). You may use, modify, and redistribute this software for any noncommercial purpose, including personal study, research, teaching, and use by educational or other noncommercial organizations. Commercial use requires a separate license from the copyright holder.

For commercial licensing inquiries, please [open an issue on this repository](https://github.com/pdfinn/tbl4-ai-stack/issues/new).

---

<p align="center">
  <a href="https://github.com/Tarkas-Brainlab-IV">Tarkas Brainlab IV</a>
</p>
