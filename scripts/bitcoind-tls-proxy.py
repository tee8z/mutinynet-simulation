#!/usr/bin/env python3

import base64
import json
import os
import socket
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib import error, request
from urllib.parse import urljoin


TARGET_URL = ""
RPC_USER = ""
RPC_PASS = ""
TIMEOUT = 60.0


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def truthy(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "on"}


def log(message: str) -> None:
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {message}", flush=True)


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


def run_rpc_proxy() -> int:
    global TARGET_URL, RPC_USER, RPC_PASS, TIMEOUT

    TARGET_URL = os.environ["BITCOIND_RPC_TARGET_URL"].rstrip("/") + "/"
    RPC_USER = os.environ.get("BITCOIND_RPC_USER", "")
    RPC_PASS = os.environ.get("BITCOIND_RPC_PASS", "")
    TIMEOUT = float(os.environ.get("BITCOIND_RPC_PROXY_TIMEOUT", "60"))

    host = os.environ.get("BITCOIND_RPC_PROXY_HOST", "127.0.0.1")
    port = int(os.environ.get("BITCOIND_RPC_PROXY_PORT", "38332"))
    server = ReusableThreadingHTTPServer((host, port), RpcProxyHandler)
    print(f"bitcoind rpc proxy listening on {host}:{port} -> {TARGET_URL}", flush=True)
    server.serve_forever()
    return 0


def pump(src: socket.socket, dst: socket.socket) -> None:
    try:
        while True:
            data = src.recv(64 * 1024)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for sock, how in ((dst, socket.SHUT_WR), (src, socket.SHUT_RD)):
            try:
                sock.shutdown(how)
            except OSError:
                pass


def handle_tcp_client(
    client: socket.socket,
    client_addr: tuple[str, int],
    target_host: str,
    target_port: int,
    server_name: str,
    insecure: bool,
) -> None:
    upstream = None
    tls_sock = None
    try:
        raw = socket.create_connection((target_host, target_port), timeout=15)
        raw.settimeout(None)
        context = ssl.create_default_context()
        if insecure:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        tls_sock = context.wrap_socket(raw, server_hostname=server_name)
        tls_sock.settimeout(None)
        upstream = tls_sock
        log(f"{client_addr[0]}:{client_addr[1]} connected to {target_host}:{target_port} sni={server_name}")

        left = threading.Thread(target=pump, args=(client, upstream), daemon=True)
        right = threading.Thread(target=pump, args=(upstream, client), daemon=True)
        left.start()
        right.start()
        left.join()
        right.join()
    except Exception as exc:
        log(f"{client_addr[0]}:{client_addr[1]} failed: {exc}")
    finally:
        for sock in (client, upstream, tls_sock):
            if sock is None:
                continue
            try:
                sock.close()
            except OSError:
                pass


def run_tcp_tls_proxy() -> int:
    listen_host = env("BITCOIND_TLS_PROXY_LISTEN_HOST", "127.0.0.1")
    listen_port = int(env("BITCOIND_TLS_PROXY_LISTEN_PORT"))
    target_host = env("BITCOIND_TLS_PROXY_TARGET_HOST")
    target_port = int(env("BITCOIND_TLS_PROXY_TARGET_PORT"))
    server_name = env("BITCOIND_TLS_PROXY_SERVER_NAME", target_host)
    insecure = truthy(env("BITCOIND_TLS_PROXY_INSECURE_SKIP_VERIFY", "0"))

    if not target_host:
        print("BITCOIND_TLS_PROXY_TARGET_HOST is required in tcp mode", file=sys.stderr)
        return 2

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((listen_host, listen_port))
        listener.listen(128)
        log(f"listening {listen_host}:{listen_port} -> tls://{target_host}:{target_port} sni={server_name}")

        while True:
            client, addr = listener.accept()
            client.settimeout(None)
            thread = threading.Thread(
                target=handle_tcp_client,
                args=(client, addr, target_host, target_port, server_name, insecure),
                daemon=True,
            )
            thread.start()


def main() -> int:
    mode = env("BITCOIND_TLS_PROXY_MODE", "rpc" if "BITCOIND_RPC_TARGET_URL" in os.environ else "tcp")
    if mode == "rpc":
        return run_rpc_proxy()
    if mode == "tcp":
        return run_tcp_tls_proxy()
    print(f"unknown BITCOIND_TLS_PROXY_MODE={mode}; expected rpc or tcp", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
