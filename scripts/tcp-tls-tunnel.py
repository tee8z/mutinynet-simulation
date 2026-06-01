#!/usr/bin/env python3

import os
import socket
import ssl
import sys
import threading
import time


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


LISTEN_HOST = env("TCP_TLS_TUNNEL_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(env("TCP_TLS_TUNNEL_LISTEN_PORT"))
TARGET_HOST = env("TCP_TLS_TUNNEL_TARGET_HOST")
TARGET_PORT = int(env("TCP_TLS_TUNNEL_TARGET_PORT"))
SERVER_NAME = env("TCP_TLS_TUNNEL_SERVER_NAME", TARGET_HOST)
INSECURE = env("TCP_TLS_TUNNEL_INSECURE_SKIP_VERIFY", "0").lower() in {
    "1",
    "true",
    "yes",
    "on",
}


def log(message: str) -> None:
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {message}", flush=True)


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


def handle(client: socket.socket, client_addr: tuple[str, int]) -> None:
    upstream = None
    tls_sock = None
    try:
        raw = socket.create_connection((TARGET_HOST, TARGET_PORT), timeout=15)
        raw.settimeout(None)
        context = ssl.create_default_context()
        if INSECURE:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        tls_sock = context.wrap_socket(raw, server_hostname=SERVER_NAME)
        tls_sock.settimeout(None)
        upstream = tls_sock
        log(f"{client_addr[0]}:{client_addr[1]} connected to {TARGET_HOST}:{TARGET_PORT} sni={SERVER_NAME}")

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


def main() -> int:
    if not TARGET_HOST:
        print("TCP_TLS_TUNNEL_TARGET_HOST is required", file=sys.stderr)
        return 2

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((LISTEN_HOST, LISTEN_PORT))
        listener.listen(128)
        log(f"listening {LISTEN_HOST}:{LISTEN_PORT} -> tls://{TARGET_HOST}:{TARGET_PORT} sni={SERVER_NAME}")

        while True:
            client, addr = listener.accept()
            client.settimeout(None)
            thread = threading.Thread(target=handle, args=(client, addr), daemon=True)
            thread.start()


if __name__ == "__main__":
    raise SystemExit(main())
