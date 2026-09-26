#!/usr/bin/env python3
"""WoL relay listener — stdlib only. Runs on markslone (systemd nexo-wol).
Endpoint contract (archive-validated): POST /wake {"mac": "..."} from the
Cloudflare edge worker over the private mesh; broadcasts the 6x FF + 16x MAC
magic packet to UDP 9 on the LAN. GET /health returns 200 for probes.
Env: WOL_LISTEN_PORT (default 9000), TARGET_APPLIANCE_MAC (default target),
WOL_BROADCAST (default 192.168.1.255).
"""
import json
import os
import re
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = int(os.environ.get("WOL_LISTEN_PORT", "9000"))
DEFAULT_MAC = os.environ.get("TARGET_APPLIANCE_MAC", "").strip()
BROADCAST = os.environ.get("WOL_BROADCAST", "192.168.1.255")
MAC_RE = re.compile(r"^([0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}$")


def build_magic_packet(mac):
    octets = [int(b, 16) for b in re.split(r"[:\-]", mac)]
    if len(octets) != 6:
        raise ValueError("malformed MAC: %s" % mac)
    return b"\xff" * 6 + bytes(octets) * 16


def send_wol(mac):
    packet = build_magic_packet(mac)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.sendto(packet, (BROADCAST, 9))
        sock.sendto(packet, (BROADCAST, 7))
    finally:
        sock.close()


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/health", "/"):
            self._send(200, {"status": "ok", "service": "nexo-wol", "port": LISTEN_PORT})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/wake":
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b"{}"
            payload = json.loads(raw.decode("utf-8") or "{}")
        except Exception as exc:
            self._send(400, {"error": "invalid json", "detail": repr(exc)})
            return
        mac = str(payload.get("mac") or DEFAULT_MAC).strip()
        if not MAC_RE.match(mac):
            self._send(400, {"error": "mac missing or malformed", "hint": "set TARGET_APPLIANCE_MAC or pass {\"mac\":\"aa:bb:cc:dd:ee:ff\"}"})
            return
        try:
            send_wol(mac)
        except Exception as exc:
            self._send(500, {"error": "send failed", "detail": repr(exc)})
            return
        self._send(200, {"status": "woke", "mac": mac, "broadcast": BROADCAST})

    def log_message(self, fmt, *args):
        sys.stderr.write("[nexo-wol] %s\n" % (fmt % args))


def main():
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    sys.stderr.write("[nexo-wol] listening on :%d (default mac: %s)\n" % (LISTEN_PORT, DEFAULT_MAC or "unset"))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
