#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""A throwaway HTTP endpoint for the director probe's HTTP transport check.

It stands where the MCP service would: it logs every POST /events body as a
line of JSON and answers GET /actions with one queued action. Usage:

    python3 http_sink.py <port> <log file>

It binds to 127.0.0.1 only. Stop it by its PID when the probe is done.
See docs/director.md, "What was verified".
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def _log(self, what):
        with open(LOG, "a") as f:
            f.write(json.dumps(what) + "\n")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode("utf-8", "replace")
        self._log({"method": "POST", "path": self.path, "body": body,
                   "ua": self.headers.get("User-Agent")})
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        self._log({"method": "GET", "path": self.path})
        out = json.dumps({"v": 1, "actions": [{"id": "a1", "based_on": 1,
                          "type": "speak", "as": "entity:@probe", "text": "hello"}]})
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(out.encode())

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
