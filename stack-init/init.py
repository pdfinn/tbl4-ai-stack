#!/usr/bin/env python3
"""
Zero-click bootstrap for tbl4-ai-stack.

  1. Wait for n8n; create/login the owner; activate every seeded workflow.
  2. Wait for OpenWebUI; create/login the admin; ensure the Summarise URL
     tool is registered (create or update).

Fully idempotent — every step is safe to re-run, so PROFILES / MODEL /
ports changes in .env take effect on the next setup re-run without
needing a volume wipe. Pure stdlib — no pip installs.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

N8N_URL = os.environ.get("N8N_URL", "http://n8n:5678")
OWUI_URL = os.environ.get("OWUI_URL", "http://open-webui:8080")
OWNER_EMAIL = os.environ.get("OWNER_EMAIL", "student@example.com")
OWNER_PASSWORD = os.environ.get("OWNER_PASSWORD", "Ai-classroom-2026")
TOOL_PATH = os.environ.get("TOOL_PATH", "/app/openwebui-tools/summarise_url.py")


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


def wait_for(url, timeout=600):
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
        "firstName": "Classroom",
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


def owui_token():
    """Return an admin bearer token — sign up if first run, sign in otherwise."""
    code, body, _ = request(f"{OWUI_URL}/api/config")
    if code != 200:
        sys.exit(f"OpenWebUI config probe failed: HTTP {code}")
    # OpenWebUI v0.9.1's /api/config doesn't expose an `onboarding` field;
    # `features.enable_signup` is the canonical "is the admin slot still
    # open?" signal -- true on a virgin install, flipped to false the
    # moment a user is created.
    cfg = json.loads(body)
    if cfg.get("features", {}).get("enable_signup", True):
        code, body, _ = request(f"{OWUI_URL}/api/v1/auths/signup", "POST", {
            "name": "Student",
            "email": OWNER_EMAIL,
            "password": OWNER_PASSWORD,
        })
        if code != 200:
            sys.exit(f"OpenWebUI signup failed: HTTP {code} {body[:200]}")
        print("  owui: admin created", flush=True)
    else:
        code, body, _ = request(f"{OWUI_URL}/api/v1/auths/signin", "POST", {
            "email": OWNER_EMAIL,
            "password": OWNER_PASSWORD,
        })
        if code != 200:
            sys.exit(f"OpenWebUI signin failed: HTTP {code} {body[:200]}")
        print("  owui: signed in (already onboarded)", flush=True)
    return json.loads(body)["token"]


def setup_owui():
    wait_for(f"{OWUI_URL}/health")
    token = owui_token()
    auth = {"Authorization": f"Bearer {token}"}

    with open(TOOL_PATH) as f:
        tool_source = f.read()
    payload = {
        "id": "summarise_url",
        "name": "Summarise URL",
        "content": tool_source,
        "meta": {
            "description": "Fetch a web page and ask n8n to summarise it.",
            "manifest": {},
        },
    }
    # Try create; if the tool already exists, update it. Update is the path
    # that lets PROFILES/MODEL/credential changes flow through to the running
    # OpenWebUI without a volume wipe.
    code, body, _ = request(f"{OWUI_URL}/api/v1/tools/create", "POST", payload, headers=auth)
    if code == 200:
        print("  owui: registered Summarise URL tool", flush=True)
        return
    code, body, _ = request(
        f"{OWUI_URL}/api/v1/tools/id/summarise_url/update", "POST", payload, headers=auth,
    )
    if code != 200:
        sys.exit(f"OpenWebUI tool register/update failed: HTTP {code} {body[:200]}")
    print("  owui: updated Summarise URL tool", flush=True)


def main():
    print("=== n8n ===", flush=True)
    setup_n8n()
    print("=== OpenWebUI ===", flush=True)
    setup_owui()
    print("=== done ===", flush=True)


if __name__ == "__main__":
    main()
