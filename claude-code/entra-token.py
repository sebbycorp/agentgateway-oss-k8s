#!/usr/bin/env python3
"""Microsoft Entra ID sign-in for the Claude Code agentgateway profile.

Claude Code runs this to get the token it sends to the gateway. Needs only Python 3 and curl.

  entra-token.py            print a valid access token (Claude Code's apiKeyHelper)
  entra-token.py headers    print {"Authorization": "Bearer ..."} (MCP headersHelper)
  entra-token.py login      open the Microsoft sign-in page in the browser
  entra-token.py ensure     sign in only if there is no usable sign-in (used by the claude-agw alias)
  entra-token.py logout     forget the sign-in

Reads the tenant and app IDs from entra.json next to this file. Keeps the tokens in
entra-token.json next to this file, readable only by you. The app registration is a
public client, so there is no client secret.
"""
import base64, hashlib, http.server, json, os, secrets, subprocess, sys, time, urllib.parse
import webbrowser

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "entra-token.json")
with open(os.path.join(HERE, "entra.json")) as f:
    CFG = json.load(f)
TENANT, APP = CFG["tenantId"], CFG["appId"]
SCOPE = f"api://{APP}/access offline_access"
AUTHORITY = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0"
REFRESH_BEFORE = 600   # get a new token when the current one has under 10 minutes left
LOGIN_TIMEOUT = 300    # seconds to wait for the browser sign-in


def load():
    try:
        with open(CACHE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save(tok):
    data = {
        "access_token": tok["access_token"],
        "expires_at": int(time.time()) + int(tok.get("expires_in", 3600)),
        "refresh_token": tok.get("refresh_token") or load().get("refresh_token"),
    }
    fd = os.open(CACHE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    return data


def token_request(fields):
    # curl rather than urllib: it uses the system certificate store, which some Python
    # installs on macOS do not. The form body goes over stdin, not the command line.
    body = urllib.parse.urlencode({"client_id": APP, "scope": SCOPE, **fields})
    r = subprocess.run(["curl", "-sS", "--max-time", "20", "--data", "@-", f"{AUTHORITY}/token"],
                       input=body, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    tok = json.loads(r.stdout)
    if "access_token" not in tok:
        raise RuntimeError(tok.get("error_description", tok.get("error", "no token returned")).splitlines()[0])
    return tok


def current():
    """A valid access token from the cache or a refresh, or None."""
    c = load()
    if c.get("access_token") and c.get("expires_at", 0) - time.time() > REFRESH_BEFORE:
        return c["access_token"]
    if c.get("refresh_token"):
        try:
            return save(token_request({"grant_type": "refresh_token", "refresh_token": c["refresh_token"]}))["access_token"]
        except (RuntimeError, ValueError, OSError):
            pass
    # The refresh failed (offline, or sign-in expired): use the old token while it is still valid.
    if c.get("access_token") and c.get("expires_at", 0) - time.time() > 30:
        return c["access_token"]
    return None


def login():
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            q = dict(urllib.parse.parse_qsl(url.query))
            if url.path != "/callback" or q.get("state") != state:
                self.send_error(404)
                return
            result.update(q)
            ok = "code" in q
            self.send_response(200 if ok else 400)
            self.send_header("content-type", "text/html; charset=utf-8")
            self.end_headers()
            msg = "Signed in. You can close this tab and go back to the terminal." if ok \
                else "Sign-in failed: " + q.get("error_description", q.get("error", "unknown error"))
            self.wfile.write(f"<html><body style='font-family:sans-serif;margin:3em'>{msg}</body></html>".encode())

        def log_message(self, *a):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    # Entra ignores the port of a loopback redirect URI but matches the path exactly.
    redirect = f"http://localhost:{server.server_port}/callback"
    url = f"{AUTHORITY}/authorize?" + urllib.parse.urlencode({
        "client_id": APP, "response_type": "code", "redirect_uri": redirect, "scope": SCOPE,
        "state": state, "code_challenge": challenge, "code_challenge_method": "S256",
    })
    print("Opening the Microsoft sign-in page. If no browser opens, use this link:\n" + url, file=sys.stderr)
    webbrowser.open(url)
    deadline = time.time() + LOGIN_TIMEOUT
    while not result and time.time() < deadline:
        server.timeout = 1
        server.handle_request()
    server.server_close()
    if "code" not in result:
        sys.exit("Sign-in failed: " + result.get("error_description", "no answer from the browser in time"))
    try:
        save(token_request({"grant_type": "authorization_code", "code": result["code"],
                            "redirect_uri": redirect, "code_verifier": verifier}))
    except (RuntimeError, ValueError) as e:
        sys.exit(f"Sign-in failed: {e}")
    print("Signed in.", file=sys.stderr)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "token"
    if cmd == "login":
        login()
    elif cmd == "ensure":
        if not current():
            login()
    elif cmd == "logout":
        if os.path.exists(CACHE):
            os.remove(CACHE)
    elif cmd in ("token", "headers"):
        tok = current()
        if not tok:
            # Never open a browser from here: Claude Code runs this in the background.
            sys.exit(f"Not signed in to Entra ID. Run: {os.path.abspath(__file__)} login")
        print(json.dumps({"Authorization": f"Bearer {tok}"}) if cmd == "headers" else tok)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
