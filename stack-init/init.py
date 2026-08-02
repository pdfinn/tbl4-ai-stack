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


def request_json(url, method="GET", data=None, headers=None, cookies=None,
                 what=None, attempts=5, delay=2):
    """request(), but returning the parsed JSON body as well.

    A service can answer 200 with an empty or partial body for a short window
    while it is still coming up. Observed on a genuinely fresh install: n8n's
    /rest/settings readiness probe goes green before /rest/workflows reliably
    returns content, so the very next call got HTTP 200 with a zero-length
    body. json.loads() then blew up with a traceback and bootstrapping died
    half-done -- the containers were left running and the stack silently
    misconfigured.

    Treat an unparseable 200 as "not ready yet" and retry, then give up with a
    readable message instead of a stack trace.
    """
    body = ""
    for attempt in range(attempts):
        code, body, hdrs = request(url, method, data, headers=headers, cookies=cookies)
        if code != 200:
            return code, None, body, hdrs
        try:
            return code, json.loads(body), body, hdrs
        except ValueError:
            if attempt < attempts - 1:
                time.sleep(delay)
    sys.exit(
        f"{what or url}: HTTP 200 but the body was not JSON after {attempts} attempts "
        f"({len(body)} bytes received). The service may still be starting up — "
        f"re-run setup."
    )


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

    code, parsed, body, _ = request_json(f"{N8N_URL}/rest/workflows", cookies=cookies,
                                         what="n8n list workflows")
    if code != 200:
        sys.exit(f"n8n list workflows failed: HTTP {code}")
    workflows = parsed.get("data", [])
    if not workflows:
        print("  n8n: no workflows to activate", flush=True)
        return
    for w in workflows:
        if w.get("active"):
            print(f"  n8n: {w['name']!r} already active", flush=True)
            continue
        code, parsed, body, _ = request_json(f"{N8N_URL}/rest/workflows/{w['id']}",
                                             cookies=cookies,
                                             what=f"n8n get workflow {w['id']!r}")
        if code != 200:
            sys.exit(f"n8n get workflow {w['id']!r} failed: HTTP {code}")
        version_id = parsed["data"]["versionId"]
        code, body, _ = request(
            f"{N8N_URL}/rest/workflows/{w['id']}/activate",
            "POST", {"versionId": version_id}, cookies=cookies,
        )
        if code != 200:
            sys.exit(f"n8n activate {w['id']!r} failed: HTTP {code} {body[:200]}")
        print(f"  n8n: activated {w['name']!r}", flush=True)


def owui_token():
    """Return an admin bearer token — sign up if first run, sign in otherwise."""
    code, cfg, body, _ = request_json(f"{OWUI_URL}/api/config",
                                      what="OpenWebUI config probe")
    if code != 200:
        sys.exit(f"OpenWebUI config probe failed: HTTP {code}")
    # OpenWebUI v0.9.1's /api/config doesn't expose an `onboarding` field;
    # `features.enable_signup` is the canonical "is the admin slot still
    # open?" signal -- true on a virgin install, flipped to false the
    # moment a user is created.
    if cfg.get("features", {}).get("enable_signup", True):
        code, parsed, body, _ = request_json(f"{OWUI_URL}/api/v1/auths/signup", "POST", {
            "name": "Student",
            "email": OWNER_EMAIL,
            "password": OWNER_PASSWORD,
        }, what="OpenWebUI signup")
        if code != 200:
            sys.exit(f"OpenWebUI signup failed: HTTP {code} {body[:200]}")
        print("  owui: admin created", flush=True)
    else:
        code, parsed, body, _ = request_json(f"{OWUI_URL}/api/v1/auths/signin", "POST", {
            "email": OWNER_EMAIL,
            "password": OWNER_PASSWORD,
        }, what="OpenWebUI signin")
        if code != 200:
            sys.exit(f"OpenWebUI signin failed: HTTP {code} {body[:200]}")
        print("  owui: signed in (already onboarded)", flush=True)
    return parsed["token"]


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
