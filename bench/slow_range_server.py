"""A local HTTP server with Range support and a fixed delay per request, to
make round trips deterministic when benchmarking remote reads.

    python3 -I bench/slow_range_server.py DIR PORT DELAY_SECONDS [BYTES_PER_SECOND]

Threaded, so concurrent requests overlap as they would against a real host.
Logs one line per request to stderr (method, range, time).
"""
import os
import re
import sys
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ROOT, PORT, DELAY = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
# per-connection bandwidth (0: unlimited), as a CDN's per-request throughput
RATE = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0


class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def __init__(self, *a, **k):
        super().__init__(*a, directory=ROOT, **k)

    def _send(self, head_only):
        time.sleep(DELAY)
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            self.send_error(404)
            return
        size = os.path.getsize(path)
        rng = self.headers.get("Range")
        m = re.match(r"bytes=(\d+)-(\d*)$", rng or "")
        if m:
            start = int(m.group(1))
            end = min(int(m.group(2)) if m.group(2) else size - 1, size - 1)
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            start, end = 0, size - 1
            self.send_response(200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        if not head_only:
            with open(path, "rb") as f:
                f.seek(start)
                left = end - start + 1
                while left > 0:
                    buf = f.read(min(left, 65536))
                    self.wfile.write(buf)
                    left -= len(buf)
                    if RATE > 0:
                        time.sleep(len(buf) / RATE)
        sys.stderr.write(f"{time.time():.3f} {self.command} {rng}\n")

    def do_GET(self):
        self._send(False)

    def do_HEAD(self):
        self._send(True)

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
