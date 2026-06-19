import hashlib
import json
import math
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "21435"))
MODEL = os.getenv("EMBEDDING_MODEL", "liquidation-hash-embedding-1024")
DIMENSION = int(os.getenv("EMBEDDING_DIM", "1024"))
TOKEN_RE = re.compile(r"\w+", re.UNICODE)


def _tokens(value):
    tokens = TOKEN_RE.findall(str(value).lower())
    return tokens if tokens else [""]


def _embed(value):
    vector = [0.0] * DIMENSION
    for token in _tokens(value):
        digest = hashlib.blake2b(token.encode("utf-8"), digest_size=16).digest()
        index = int.from_bytes(digest[:4], "little") % DIMENSION
        sign = 1.0 if digest[4] & 1 else -1.0
        vector[index] += sign

    norm = math.sqrt(sum(item * item for item in vector)) or 1.0
    return [item / norm for item in vector]


def _normalize_input(raw_input):
    if isinstance(raw_input, list):
        return [item if isinstance(item, str) else json.dumps(item, ensure_ascii=False) for item in raw_input]
    return [str(raw_input)]


class Handler(BaseHTTPRequestHandler):
    server_version = "liquidation-embeddings/0.1"

    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def do_GET(self):
        if self.path in ("/", "/health"):
            self._send_json(200, {"status": "ok", "model": MODEL, "dimension": DIMENSION})
            return

        if self.path == "/v1/models":
            self._send_json(
                200,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": MODEL,
                            "object": "model",
                            "owned_by": "liquidation",
                        }
                    ],
                },
            )
            return

        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/v1/embeddings":
            self._send_json(404, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            request = json.loads(self.rfile.read(length).decode("utf-8") if length else "{}")
            model = request.get("model") or MODEL
            if model != MODEL:
                self._send_json(400, {"error": "unsupported model", "model": model})
                return

            inputs = _normalize_input(request.get("input", ""))
            data = [
                {
                    "object": "embedding",
                    "index": index,
                    "embedding": _embed(item),
                }
                for index, item in enumerate(inputs)
            ]
            token_count = sum(len(_tokens(item)) for item in inputs)
            self._send_json(
                200,
                {
                    "object": "list",
                    "model": MODEL,
                    "data": data,
                    "usage": {
                        "prompt_tokens": token_count,
                        "total_tokens": token_count,
                    },
                },
            )
        except Exception as exc:
            self._send_json(500, {"error": str(exc)})


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"liquidation embedding server listening on {HOST}:{PORT} model={MODEL} dim={DIMENSION}", flush=True)
    server.serve_forever()
