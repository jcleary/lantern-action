#!/usr/bin/env python3
"""A tiny stand-in for Lantern's POST /api/v1/reports, for the action's tests. Stdlib only.

It serves HTTPS (the action refuses plain http), answers from a scenario file, and logs one JSON
line per request to --log so tests can assert what the action actually sent.

Scenario file:
  {
    "routes":  { "<source>": [ <response>, <response>, ... ] },   # consumed in order, last repeats
    "default": <response>                                          # for sources without a route
  }
  <response> = { "status": 201, "body": {...} | "text", "headers": { "Retry-After": "1" } }

Faithful bits: a missing/form Content-Type gets SvelteKit's plain-text 403; a missing Authorization
header gets a JSON 401; the Authorization value is never logged, only whether it matched --expect-key.

Self-checking: if the previous response for a source was retryable (429/5xx) and the next request for
it carries a different scannedAt, the hit is logged with "violation" set (the action must reuse it).
"""
import argparse
import hashlib
import json
import os
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LOCK = threading.Lock()
STATE = {"index": {}, "last": {}, "n": 0}


def make_handler(args, scenario):
    class Handler(BaseHTTPRequestHandler):
        server_version = "lantern-mock"

        def log_message(self, *_):  # silence default stderr logging
            pass

        def _send(self, status, body=None, headers=None):
            payload = b""
            ctype = "application/json"
            if isinstance(body, (dict, list)):
                payload = json.dumps(body).encode()
            elif isinstance(body, str):
                payload = body.encode()
                ctype = "text/plain"
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(payload)))
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(payload)

        def do_POST(self):
            parsed = urlparse(self.path)
            q = {k: v[0] for k, v in parse_qs(parsed.query).items()}
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length)
            source = q.get("source", "")
            ctype = self.headers.get("Content-Type", "")
            auth = self.headers.get("Authorization", "")

            hit = {
                "path": parsed.path,
                "source": source,
                "format": q.get("format"),
                "scannedAt": q.get("scannedAt"),
                "content_type": ctype,
                "user_agent": self.headers.get("User-Agent", ""),
                "has_auth": auth.startswith("Bearer "),
                "auth_ok": bool(args.expect_key) and auth == "Bearer " + args.expect_key,
                "body_bytes": len(raw),
                "body_sha256": hashlib.sha256(raw).hexdigest(),
            }

            with LOCK:
                STATE["n"] += 1
                n = STATE["n"]
                if args.bodies_dir:
                    os.makedirs(args.bodies_dir, exist_ok=True)
                    with open(os.path.join(args.bodies_dir, f"{n:03d}-{source}.json"), "wb") as f:
                        f.write(raw)
                    hit["body_file"] = f"{n:03d}-{source}.json"

                if parsed.path != "/api/v1/reports":
                    status, body, headers = 404, {"error": {"code": "not_found", "message": "no such route"}}, {}
                elif not ctype.lower().startswith("application/json"):
                    status, body, headers = 403, "Cross-site POST form submissions are forbidden", {}
                elif not hit["has_auth"]:
                    status, body, headers = 401, {"error": {"code": "unauthorized", "message": "Invalid or missing API key."}}, {"WWW-Authenticate": "Bearer"}
                else:
                    routes = scenario.get("routes", {})
                    seq = routes.get(source)
                    if seq is None:
                        seq = [scenario.get("default", {"status": 201, "body": {"runId": "default", "source": source, "opened": 0, "closed": 0, "reopened": 0, "open": {"critical": 0, "high": 0, "medium": 0, "low": 0}}})]
                    i = STATE["index"].get(source, 0)
                    resp = seq[min(i, len(seq) - 1)]
                    STATE["index"][source] = i + 1
                    status, body, headers = resp.get("status", 200), resp.get("body"), resp.get("headers", {})

                prev = STATE["last"].get(source)
                if prev and (prev[0] == 429 or prev[0] >= 500) and prev[1] != hit["scannedAt"]:
                    hit["violation"] = "scannedAt changed on a retry"
                STATE["last"][source] = (status, hit["scannedAt"])
                hit["status"] = status
                with open(args.log, "a") as f:
                    f.write(json.dumps(hit) + "\n")

            self._send(status, body, headers)

        do_GET = do_POST

    return Handler


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--cert", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--scenario", required=True)
    p.add_argument("--log", required=True)
    p.add_argument("--port-file", required=True, help="written once the server is listening")
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--expect-key", default="")
    p.add_argument("--bodies-dir", default="")
    args = p.parse_args()

    with open(args.scenario) as f:
        scenario = json.load(f)
    open(args.log, "a").close()

    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(args, scenario))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(args.cert, args.key)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    with open(args.port_file, "w") as f:
        f.write(str(httpd.server_address[1]))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
