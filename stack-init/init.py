#!/usr/bin/env python3
"""
Zero-click bootstrap for tbl4-stack.

  1. Wait for n8n; create the owner; activate every seeded workflow.
  2. Wait for OpenWebUI; create the admin; register the Summarise URL tool.

Idempotent. A sentinel file in /state lets us skip on re-runs of an already
initialised volume; individual API steps also handle "already exists" gracefully.
Pure stdlib — no pip installs.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

N8N_URL = os.environ.get("N8N_URL", "http://n8n:5678")
OWUI_URL = os.environ.get("OWUI_URL", "http://open-webui:8080")
OWNER_EMAIL = os.environ.get("OWNER_EMAIL", "tbl4@example.com")
OWNER_PASSWORD = os.environ.get("OWNER_PASSWORD", "Tbl4-classroom-2026!")
TOOL_PATH = os.environ.get("TOOL_PATH", "/app/openwebui-tools/summarise_url.py")
SENTINEL = "/state/.tbl4-stack-init"


def request(url, method="GET", data=None, headers=None, cookies=None):
    body = json.dumps(data).encode() if data is not None else None
    h = {"Content-Type": "application/json"} if data else {}
    if headers:
        h.update(headers)
    if cookies:
        h["Cookie"] = "; ".join(f"{k}={v}" for k, v in cookies.items())
    req = urllib.request.Request(url, data=body, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), dict(e.headers)


def wait_for(url, timeout=180):
    print(f"waiting for {url}", flush=True)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                if r.status == 200:
                    return
        except Exception:
            pass
        time.sleep(2)
    raise TimeoutError(f"{url} not ready after {timeout}s")


def parse_set_cookie(headers):
    raw = headers.get("Set-Cookie") or headers.get("set-cookie") or ""
    # Multiple Set-Cookie headers are comma-joined by urllib; split carefully —
    # the Expires attribute also contains a comma, so split on cookie boundaries.
    cookies = {}
    for chunk in raw.split(", "):
        first = chunk.split(";", 1)[0].strip()
        if "=" in first and "/" not in first.split("=", 1)[0]:
            k, v = first.split("=", 1)
            cookies[k.strip()] = v.strip()
    return cookies


def setup_n8n():
    # /rest/settings is the right readiness probe: /healthz comes up before
    # the REST router is mounted, so polling /healthz can give us a working
    # service that 404s on /rest/owner/setup.
    wait_for(f"{N8N_URL}/rest/settings")
    code, body, headers = request(f"{N8N_URL}/rest/owner/setup", "POST", {
        "email": OWNER_EMAIL,
        "password": OWNER_PASSWORD,
        "firstName": "TBL4",
        "lastName": "Student",
    })
    if code == 200:
        print("  n8n: owner created", flush=True)
        cookies = parse_set_cookie(headers)
    elif code == 400:
        print("  n8n: owner exists — logging in", flush=True)
        code, _, headers = request(f"{N8N_URL}/rest/login", "POST", {
            "emailOrLdapLoginId": OWNER_EMAIL,
            "password": OWNER_PASSWORD,
        })
        if code != 200:
            sys.exit(f"n8n login failed: HTTP {code}")
        cookies = parse_set_cookie(headers)
    else:
        sys.exit(f"n8n owner setup failed: HTTP {code} {body[:200]}")

    code, body, _ = request(f"{N8N_URL}/rest/workflows", cookies=cookies)
    if code != 200:
        sys.exit(f"n8n list workflows failed: HTTP {code}")
    workflows = json.loads(body).get("data", [])
    if not workflows:
        print("  n8n: no workflows to activate", flush=True)
        return
    for w in workflows:
        if w.get("active"):
            print(f"  n8n: {w['name']!r} already active", flush=True)
            continue
        code, body, _ = request(f"{N8N_URL}/rest/workflows/{w['id']}", cookies=cookies)
        if code != 200:
            sys.exit(f"n8n get workflow {w['id']!r} failed: HTTP {code}")
        version_id = json.loads(body)["data"]["versionId"]
        code, body, _ = request(
            f"{N8N_URL}/rest/workflows/{w['id']}/activate",
            "POST", {"versionId": version_id}, cookies=cookies,
        )
        if code != 200:
            sys.exit(f"n8n activate {w['id']!r} failed: HTTP {code} {body[:200]}")
        print(f"  n8n: activated {w['name']!r}", flush=True)


def setup_owui():
    wait_for(f"{OWUI_URL}/health")
    code, body, _ = request(f"{OWUI_URL}/api/config")
    if code != 200:
        sys.exit(f"OpenWebUI config probe failed: HTTP {code}")
    cfg = json.loads(body)
    if not cfg.get("onboarding", True):
        # Onboarded already; with WEBUI_AUTH=false we cannot retrieve a token,
        # so trust prior init landed the tool. Sentinel will short-circuit
        # next time, so this branch only fires on partial-init recovery.
        print("  owui: already onboarded — skipping admin signup", flush=True)
        return
    code, body, _ = request(f"{OWUI_URL}/api/v1/auths/signup", "POST", {
        "name": "TBL4",
        "email": OWNER_EMAIL,
        "password": OWNER_PASSWORD,
    })
    if code != 200:
        sys.exit(f"OpenWebUI signup failed: HTTP {code} {body[:200]}")
    token = json.loads(body)["token"]
    print("  owui: admin created", flush=True)

    with open(TOOL_PATH) as f:
        tool_source = f.read()
    code, body, _ = request(
        f"{OWUI_URL}/api/v1/tools/create",
        "POST",
        {
            "id": "summarise_url",
            "name": "Summarise URL",
            "content": tool_source,
            "meta": {
                "description": "Fetch a web page and ask n8n to summarise it.",
                "manifest": {},
            },
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    if code != 200:
        sys.exit(f"OpenWebUI tool register failed: HTTP {code} {body[:200]}")
    print("  owui: registered Summarise URL tool", flush=True)


def main():
    if os.path.exists(SENTINEL):
        print("already initialised; skipping")
        return
    print("=== n8n ===", flush=True)
    setup_n8n()
    print("=== OpenWebUI ===", flush=True)
    setup_owui()
    os.makedirs(os.path.dirname(SENTINEL), exist_ok=True)
    open(SENTINEL, "w").close()
    print("=== done ===", flush=True)


if __name__ == "__main__":
    main()
