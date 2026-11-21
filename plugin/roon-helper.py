#!/usr/bin/env python3
"""Bridge between the Omarchy bar widget and a Roon Core.

Registers with the Core as a Roon extension (the MOO protocol over a
WebSocket), follows its zones, and exchanges JSON lines with the widget:
events go to stdout, commands come in on stdin. Standard library only.

Events:   {"type": "status", "status": "...", "core": "...", "message": "..."}
          {"type": "zones", "zones": [...]}
          {"type": "art", "key": "...", "path": "..."}
Commands: {"cmd": "control", "zone": "...", "control": "playpause|next|previous"}
          {"cmd": "transfer", "from": "...", "to": "..."}
          {"cmd": "art", "key": "..."}
"""

import argparse
import base64
import hashlib
import json
import os
import re
import socket
import struct
import sys
import threading
import time
import urllib.request

EXTENSION = {
    "extension_id": "kingscott.omarchy-roon",
    "display_name": "Omarchy Roon",
    "display_version": "0.1.0",
    "publisher": "Omarchy Roon plugin",
    "email": "noreply@example.com",
    "required_services": ["com.roonlabs.transport:2"],
    "optional_services": [],
    "provided_services": ["com.roonlabs.ping:1"],
}

MAX_MESSAGE = 4 * 1024 * 1024
MAX_ART = 2 * 1024 * 1024
MAX_TEXT = 300
ART_CACHE = 30
CONTROLS = {"playpause", "next", "previous"}
ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "omarchy-roon")
STATE_FILE = os.path.join(CONFIG_DIR, "state.json")
RUNTIME_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "omarchy-roon")
ART_DIR = os.path.join(RUNTIME_DIR, "art")

_out_lock = threading.Lock()


def emit(obj):
    with _out_lock:
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def log(message):
    print(f"omarchy-roon: {message}", file=sys.stderr, flush=True)


class WebSocket:
    """Minimal RFC 6455 client: plain TCP, binary frames, no extensions."""

    def __init__(self, host, port, path, timeout):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.send_lock = threading.Lock()
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(request.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("connection closed during handshake")
            response += chunk
            if len(response) > 16384:
                raise ConnectionError("handshake response too large")
        head, _, self.buffer = response.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        if len(lines[0].split()) < 2 or lines[0].split()[1] != "101":
            raise ConnectionError(f"handshake refused: {lines[0][:80]}")
        headers = {k.strip().lower(): v.strip() for k, _, v in (l.partition(":") for l in lines[1:])}
        expected = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        if headers.get("sec-websocket-accept") != expected:
            raise ConnectionError("handshake accept key mismatch")

    def settimeout(self, seconds):
        self.sock.settimeout(seconds)

    def _read(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(max(4096, n - len(self.buffer)))
            if not chunk:
                raise ConnectionError("connection closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:n], self.buffer[n:]
        return data

    def send(self, payload, opcode=0x2):
        header = bytearray([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header += struct.pack("!H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack("!Q", length)
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        with self.send_lock:
            self.sock.sendall(bytes(header) + mask + masked)

    def recv(self):
        message = b""
        while True:
            b1, b2 = self._read(2)
            fin, opcode = b1 & 0x80, b1 & 0x0F
            length = b2 & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read(8))[0]
            if length + len(message) > MAX_MESSAGE:
                raise ConnectionError("message too large")
            mask = self._read(4) if b2 & 0x80 else None
            payload = self._read(length)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:
                raise ConnectionError("closed by server")
            if opcode == 0x9:
                self.send(payload, opcode=0xA)
                continue
            if opcode == 0xA:
                continue
            message += payload
            if fin:
                return message

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def encode_moo(verb, name, request_id, body=None):
    lines = [f"MOO/1 {verb} {name}", f"Request-Id: {request_id}"]
    data = b""
    if body is not None:
        data = json.dumps(body).encode()
        lines += ["Content-Type: application/json", f"Content-Length: {len(data)}"]
    return ("\n".join(lines) + "\n\n").encode() + data


def decode_moo(raw):
    head, _, body = raw.partition(b"\n\n")
    lines = head.decode("utf-8", "replace").split("\n")
    match = re.match(r"^MOO/1 (REQUEST|COMPLETE|CONTINUE) (\S+)", lines[0])
    if not match:
        raise ValueError("not a MOO message")
    headers = {}
    for line in lines[1:]:
        key, _, value = line.partition(":")
        headers[key.strip().lower()] = value.strip()
    payload = None
    if body and headers.get("content-type", "").startswith("application/json"):
        payload = json.loads(body.decode("utf-8"))
    return match.group(1), match.group(2), headers, payload


def text(value):
    return str(value or "")[:MAX_TEXT]


def simplify_zone(zone):
    now = zone.get("now_playing") or {}
    lines = now.get("three_line") or {}
    image = now.get("image_key") or ""
    return {
        "id": text(zone.get("zone_id")),
        "name": text(zone.get("display_name")),
        "state": text(zone.get("state") or "stopped"),
        "title": text(lines.get("line1")),
        "artist": text(lines.get("line2")),
        "album": text(lines.get("line3")),
        "image": image if ID_RE.match(image) else "",
        "canNext": bool(zone.get("is_next_allowed")),
        "canPrevious": bool(zone.get("is_previous_allowed")),
        "canPlayPause": bool(zone.get("is_play_allowed") or zone.get("is_pause_allowed")),
    }


def load_tokens():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            tokens = json.load(f).get("tokens", {})
        return tokens if isinstance(tokens, dict) else {}
    except (OSError, ValueError):
        return {}


def save_token(core_id, token):
    tokens = load_tokens()
    tokens[core_id] = token
    os.makedirs(CONFIG_DIR, mode=0o700, exist_ok=True)
    temporary = STATE_FILE + ".tmp"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"tokens": tokens}, f)
    os.replace(temporary, STATE_FILE)


class Session:
    def __init__(self, host, port):
        self.host = host
        self.port = port
        self.ws = None
        self.next_id = 0
        self.callbacks = {}
        self.zones = {}
        self.registered = False
        self.lock = threading.Lock()

    def request(self, name, body=None, callback=None):
        with self.lock:
            if self.ws is None:
                return
            request_id = self.next_id
            self.next_id += 1
            if callback:
                self.callbacks[request_id] = callback
            ws = self.ws
        ws.send(encode_moo("REQUEST", name, request_id, body))

    def run(self):
        ws = WebSocket(self.host, self.port, "/api", timeout=10)
        with self.lock:
            self.ws = ws
        try:
            ws.settimeout(15)
            self.request("com.roonlabs.registry:1/info", callback=self.on_info)
            last_rx = time.monotonic()
            while True:
                try:
                    raw = ws.recv()
                except socket.timeout:
                    if time.monotonic() - last_rx > 45:
                        raise ConnectionError("Core stopped responding")
                    self.request("com.roonlabs.registry:1/info")
                    continue
                last_rx = time.monotonic()
                self.dispatch(raw)
        finally:
            with self.lock:
                self.ws = None
                self.callbacks.clear()
            ws.close()

    def dispatch(self, raw):
        try:
            verb, name, headers, payload = decode_moo(raw)
        except (ValueError, UnicodeDecodeError) as error:
            log(f"ignoring malformed message: {error}")
            return
        request_id = headers.get("request-id", "")
        if verb == "REQUEST":
            # The Core pings provided services; every request we get is answered.
            self.ws.send(encode_moo("COMPLETE", "Success", request_id))
            return
        try:
            key = int(request_id)
        except ValueError:
            return
        callback = self.callbacks.get(key)
        if verb == "COMPLETE":
            self.callbacks.pop(key, None)
        if callback:
            callback(name, payload or {})

    def on_info(self, name, payload):
        core_id = text(payload.get("core_id"))
        self.core_name = text(payload.get("display_name")) or "Roon Core"
        body = dict(EXTENSION)
        token = load_tokens().get(core_id)
        if token:
            body["token"] = token
        self.request("com.roonlabs.registry:1/register", body, self.on_register)
        emit({"type": "status", "status": "connecting" if token else "waiting_auth", "core": self.core_name})

    def on_register(self, name, payload):
        if name != "Registered":
            emit({"type": "status", "status": "error", "message": f"Registration failed: {text(name)}"})
            return
        if payload.get("core_id") and payload.get("token"):
            save_token(text(payload["core_id"]), str(payload["token"]))
        self.registered = True
        emit({"type": "status", "status": "connected", "core": text(payload.get("display_name")) or self.core_name})
        self.request("com.roonlabs.transport:2/subscribe_zones", {"subscription_key": 0}, self.on_zones)

    def on_zones(self, name, payload):
        if name == "Subscribed":
            self.zones = {z["zone_id"]: z for z in payload.get("zones", []) if "zone_id" in z}
        elif name == "Changed":
            for zone in payload.get("zones_added", []) + payload.get("zones_changed", []):
                if "zone_id" in zone:
                    self.zones[zone["zone_id"]] = zone
            for zone_id in payload.get("zones_removed", []):
                self.zones.pop(zone_id, None)
            if not any(k in payload for k in ("zones_added", "zones_changed", "zones_removed")):
                return
        else:
            return
        zones = sorted((simplify_zone(z) for z in self.zones.values()), key=lambda z: z["name"].lower())
        emit({"type": "zones", "zones": zones})

    def handle_command(self, command):
        if not self.registered or not isinstance(command, dict):
            return
        kind = command.get("cmd")
        if kind == "control":
            zone, control = str(command.get("zone", "")), command.get("control")
            if ID_RE.match(zone) and control in CONTROLS:
                self.request("com.roonlabs.transport:2/control", {"zone_or_output_id": zone, "control": control})
        elif kind == "transfer":
            source, target = str(command.get("from", "")), str(command.get("to", ""))
            if ID_RE.match(source) and ID_RE.match(target) and source != target:
                self.request(
                    "com.roonlabs.transport:2/transfer_zone",
                    {"from_zone_or_output_id": source, "to_zone_or_output_id": target},
                )
        elif kind == "art":
            key = str(command.get("key", ""))
            if ID_RE.match(key):
                threading.Thread(target=self.fetch_art, args=(key,), daemon=True).start()

    def fetch_art(self, key):
        path = os.path.join(ART_DIR, f"{key}.jpg")
        if not os.path.exists(path):
            url = f"http://{self.host}:{self.port}/api/image/{key}?scale=fit&width=300&height=300&format=image/jpeg"
            try:
                with urllib.request.urlopen(url, timeout=5) as response:
                    data = response.read(MAX_ART + 1)
            except OSError as error:
                log(f"album art fetch failed: {error}")
                return
            if len(data) > MAX_ART or not data.startswith(b"\xff\xd8\xff"):
                log("album art rejected: not a JPEG or too large")
                return
            os.makedirs(ART_DIR, mode=0o700, exist_ok=True)
            # Per-thread name: the widget can ask for the same image twice at once.
            temporary = f"{path}.{threading.get_ident()}.tmp"
            with open(temporary, "wb") as f:
                f.write(data)
            os.replace(temporary, path)
            prune_art()
        emit({"type": "art", "key": key, "path": path})


def prune_art():
    try:
        files = sorted(
            (os.path.join(ART_DIR, n) for n in os.listdir(ART_DIR) if n.endswith(".jpg")),
            key=os.path.getmtime,
        )
        for old in files[:-ART_CACHE]:
            os.remove(old)
    except OSError:
        pass


def read_commands(state):
    for line in sys.stdin:
        if len(line) > 4096:
            continue
        try:
            command = json.loads(line)
        except ValueError:
            continue
        session = state.get("session")
        if session:
            try:
                session.handle_command(command)
            except OSError as error:
                log(f"command failed: {error}")
    os._exit(0)  # the widget closed our stdin: it is gone, so are we


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="")
    parser.add_argument("--port", type=int, default=9330)
    args = parser.parse_args()

    host = args.host.strip()
    if not re.match(r"^[A-Za-z0-9.:-]{1,253}$", host):
        emit({"type": "status", "status": "no_host"})
        for _ in sys.stdin:
            pass
        return

    state = {}
    threading.Thread(target=read_commands, args=(state,), daemon=True).start()
    delay = 2
    while True:
        emit({"type": "status", "status": "connecting"})
        session = Session(host, args.port)
        state["session"] = session
        try:
            session.run()
        except (OSError, ConnectionError, ValueError) as error:
            log(f"connection lost: {error}")
            emit({"type": "status", "status": "error", "message": text(error)})
        state["session"] = None
        if session.registered:
            delay = 2
        time.sleep(delay)
        delay = min(delay * 2, 30)


if __name__ == "__main__":
    main()
