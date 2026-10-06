"""Minimal namchaind control client over TCP (length-prefixed JSON + token)."""
import json, socket, struct, subprocess, threading, time

class NamchainError(RuntimeError):
    pass


def fetch_token(host="vip"):
    out = subprocess.run(["ssh", host, "sudo cat /etc/namchain/token"],
                         capture_output=True, text=True, check=True)
    return out.stdout.strip()


class NamchainClient:
    def __init__(self, host="vip", port=47810, token=None):
        self.host, self.port = host, port
        self.token = token or fetch_token(host)
        self.sock = socket.create_connection((host, port), timeout=10)
        self.lock = threading.Lock()
        self._id = 0
        reply = self.call({"method": "engine.hello", "protocol": 2, "token": self.token})
        if not reply.get("ok", False):
            raise NamchainError(f"handshake failed: {reply}")
        self.hello = reply

    def call(self, message):
        with self.lock:
            self._id += 1
            message = dict(message)
            message.setdefault("id", str(self._id))
            body = json.dumps(message).encode()
            self.sock.sendall(struct.pack("<I", len(body)) + body)
            head = self._recv_exactly(4)
            length = struct.unpack("<I", head)[0]
            return json.loads(self._recv_exactly(length))

    def _recv_exactly(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise NamchainError("connection closed")
            buf += chunk
        return buf

    def levels(self):
        reply = self.call({"method": "engine.levels"})
        if not reply.get("ok", False):
            raise NamchainError(reply.get("error", reply))
        return reply.get("levels", reply)

    def status(self):
        reply = self.call({"method": "engine.status"})
        return reply.get("status", reply)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass
