"""Minimal fake Ollama endpoint for smoke_test.sh.

OpenJarvis's `serve` refuses to start with no healthy inference engine
(`get_engine` returns None -> sys.exit(1)). Engine discovery only needs
`GET /api/tags` to return 200 for the `ollama` engine to count as healthy, so
this answers that (and a token chat response) and nothing else.
"""

import json
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 11434


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):  # quiet
        pass

    def _json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/api/tags"):
            self._json({"models": [{"name": "smoke:latest", "model": "smoke:latest"}]})
        elif self.path.startswith("/api/version"):
            self._json({"version": "0.0.0-smoke"})
        else:
            self._json({})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        self._json(
            {
                "model": "smoke:latest",
                "message": {"role": "assistant", "content": "ok"},
                "done": True,
            }
        )


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
