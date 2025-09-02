#!/usr/bin/env python3
import os
import sys
import json
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import subprocess

TOKEN = os.environ.get("RUNMAP_TRIGGER_TOKEN")
LISTEN = os.environ.get("RUNMAP_TRIGGER_LISTEN", "127.0.0.1:8081")
SERVICE = os.environ.get("RUNMAP_BUFFER_SERVICE", "runmap-buffer.service")

if not TOKEN:
    print("RUNMAP_TRIGGER_TOKEN not set; refusing to start", file=sys.stderr)
    sys.exit(1)

host, sep, port = LISTEN.partition(":")
if not sep:
    host, port = "127.0.0.1", LISTEN

class Handler(BaseHTTPRequestHandler):
    def _json(self, code:int, body:dict):
        data = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path != "/trigger":
            return self._json(404, {"error":"not found"})
        # token via header or query
        hdr = self.headers.get("X-Runmap-Token", "")
        qs = parse_qs(parsed.query)
        tok = hdr or (qs.get("token", [""])[0])
        if tok != TOKEN:
            return self._json(401, {"error":"unauthorized"})
        try:
            subprocess.run(["/usr/bin/systemctl", "start", SERVICE], check=True)
            return self._json(200, {"ok": True, "service": SERVICE})
        except subprocess.CalledProcessError as e:
            return self._json(500, {"error":"failed to start service", "detail": str(e)})

    def log_message(self, *args, **kwargs):  # silence default logging
        return

if __name__ == "__main__":
    httpd = HTTPServer((host, int(port)), Handler)
    print(f"RunMap trigger listening on http://{host}:{port} → systemctl start {SERVICE}")
    httpd.serve_forever()
