# TODO

## MCP-driven tool auto-discovery is blocked upstream

**Status:** known-blocked. The `MCP Tools` workflow seeds and activates
correctly in n8n, but OpenWebUI cannot consume it because of two
independent upstream bugs — neither fixable here. The classroom-ready
path is the Python tool in `openwebui-tools/summarise_url.py`, which
this stack auto-registers via stack-init.

### Path A — OpenWebUI's native MCP client (Streamable HTTP)

Configuring an OpenWebUI Tool Server of type `mcp` pointing at
`http://n8n:5678/webhook/mcpTools/mcp/tools` results in:

```
RuntimeError: Attempted to exit cancel scope in a different task than
it was entered in
  File "/usr/local/lib/python3.11/site-packages/mcp/client/streamable_http.py",
  line 670, in streamable_http_client
```

The MCP handshake itself succeeds (protocol version negotiated, session
ID returned, tools/list works) — the bug is in the SDK's async-context
cleanup path. OpenWebUI's `MCPClient` wraps the buggy SDK and inherits
the failure. Verified still present in OpenWebUI v0.9.1.

**Re-test condition:** new OpenWebUI release that bumps the bundled
`mcp-python-sdk` past the cancel-scope fix. After bumping the image
tag in `docker-compose.yml`, register an MCP Tool Server in OpenWebUI
and confirm tool listing works.

### Path B — mcpo proxying n8n's MCP server as OpenAPI

mcpo connects to the n8n MCP server cleanly and exposes the tools as
an OpenAPI service. But n8n's `@n8n/n8n-nodes-langchain.toolHttpRequest`
(v1.1, the maximum available in n8n 2.18.2) advertises its tool input
schema as:

```json
{ "type": "object", "properties": { "input": { "type": "string" } } }
```

It uses the LangChain `DynamicTool` pattern: a single string input, with
the structured argument shape described in prose in the tool's
description. mcpo derives the OpenAPI schema from this listing, so any
LLM that obeys the schema sends `{url, focus}` directly to mcpo →
mcpo forwards to n8n → n8n's Zod validator rejects with
`expected object, received undefined, path: []`.

The fix is upstream: n8n needs to switch the HTTP Request Tool node to
`DynamicStructuredTool` so the listTools response carries the real
`{url, focus}` schema. Until then the mcpo pipeline produces a tool
the LLM cannot actually invoke.

**Re-test condition:** n8n release that publishes a higher typeVersion
of `toolHttpRequest` with structured input. Check via
`http://localhost:5678/types/nodes.json` for `version > [1, 1.1]`. After
bumping, re-export the workflow JSON and verify `tools/list` over MCP
returns a structured `inputSchema`.

### Why we don't ship a workaround proxy

A small custom OpenAPI service in front of the n8n webhook would route
around both bugs. We deliberately don't ship one: it stacks three
proxy layers (OpenWebUI → tiny proxy → n8n → tool) on top of two
upstream bugs to recover a feature that has a clean two-line fix on
either end. Better to keep the Python tool path (works, well-understood)
and revisit when one of the two bugs above lands a fix.
