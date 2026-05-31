#!/usr/bin/env python3

import base64
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib import error, request
from urllib.parse import urljoin


TARGET_URL = os.environ["BITCOIND_RPC_TARGET_URL"].rstrip("/") + "/"
RPC_USER = os.environ.get("BITCOIND_RPC_USER", "")
RPC_PASS = os.environ.get("BITCOIND_RPC_PASS", "")
TIMEOUT = float(os.environ.get("BITCOIND_RPC_PROXY_TIMEOUT", "60"))


class RpcProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        target = urljoin(TARGET_URL, self.path.lstrip("/"))

        headers = {
            "Content-Type": self.headers.get("Content-Type", "application/json"),
            "Accept": self.headers.get("Accept", "application/json"),
        }
        if self.headers.get("Authorization"):
            headers["Authorization"] = self.headers["Authorization"]
        elif RPC_USER or RPC_PASS:
            auth = base64.b64encode(f"{RPC_USER}:{RPC_PASS}".encode()).decode()
            headers["Authorization"] = f"Basic {auth}"

        proxied = request.Request(target, data=body, headers=headers, method="POST")
        try:
            with request.urlopen(proxied, timeout=TIMEOUT) as response:
                self._send_response(response.status, response.headers.items(), response.read())
        except error.HTTPError as exc:
            self._send_response(exc.code, exc.headers.items(), exc.read())
        except Exception as exc:  # Keep relay errors visible to RPC callers.
            payload = json.dumps({"error": f"bitcoind rpc proxy: {exc}"}).encode()
            self._send_response(502, [("Content-Type", "application/json")], payload)

    def do_GET(self):
        self._send_response(200, [("Content-Type", "text/plain")], b"bitcoind rpc proxy\n")

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send_response(self, status, headers, body):
        self.send_response(status)
        skipped = {"connection", "content-encoding", "content-length", "transfer-encoding"}
        for key, value in headers:
            if key.lower() not in skipped:
                self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True


def main():
    host = os.environ.get("BITCOIND_RPC_PROXY_HOST", "127.0.0.1")
    port = int(os.environ.get("BITCOIND_RPC_PROXY_PORT", "38332"))
    server = ReusableThreadingHTTPServer((host, port), RpcProxyHandler)
    print(f"bitcoind rpc proxy listening on {host}:{port} -> {TARGET_URL}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
