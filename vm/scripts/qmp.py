#!/usr/bin/env python3
"""Minimal QMP client for driving the Kiwami dev VM.

Usage:
  qmp.py screenshot <path.png>
  qmp.py key <qemu-keyname> [...]      e.g. ret, ctrl-alt-f2, kp_enter
  qmp.py type "some text"
  qmp.py status
  qmp.py raw '{"execute":"query-status"}'
"""
import json
import os
import socket
import sys
import time

SOCK = os.environ.get("QMP_SOCK", "/tmp/kiwami-qmp.sock")

# chars that need shift, and chars with non-obvious qemu keynames
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
    "&": "7", "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal",
    "{": "bracket_left", "}": "bracket_right", "|": "backslash",
    ":": "semicolon", '"': "apostrophe", "<": "comma", ">": "dot",
    "?": "slash", "~": "grave_accent",
}
PLAIN = {
    " ": "spc", "-": "minus", "=": "equal", "[": "bracket_left",
    "]": "bracket_right", "\\": "backslash", ";": "semicolon",
    "'": "apostrophe", ",": "comma", ".": "dot", "/": "slash",
    "`": "grave_accent", "\n": "ret", "\t": "tab",
}


class QMP:
    def __init__(self, path=SOCK, timeout=30):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(timeout)
        self.s.connect(path)
        self.f = self.s.makefile("rw", encoding="utf-8", newline="\n")
        self._read()                      # greeting
        self.cmd("qmp_capabilities")

    def _read(self):
        while True:
            line = self.f.readline()
            if not line:
                raise RuntimeError("QMP socket closed")
            msg = json.loads(line)
            if "event" in msg:            # skip async events
                continue
            return msg

    def cmd(self, execute, **args):
        payload = {"execute": execute}
        if args:
            payload["arguments"] = args
        self.f.write(json.dumps(payload) + "\n")
        self.f.flush()
        r = self._read()
        if "error" in r:
            raise RuntimeError(f"{execute}: {r['error']['desc']}")
        return r.get("return")

    def hmp(self, line):
        return self.cmd("human-monitor-command", **{"command-line": line})

    def sendkey(self, keys, hold_ms=50):
        self.hmp(f"sendkey {keys} {hold_ms}")

    def type(self, text):
        for ch in text:
            if ch in SHIFTED:
                self.sendkey(f"shift-{SHIFTED[ch]}")
            elif ch in PLAIN:
                self.sendkey(PLAIN[ch])
            elif ch.isupper():
                self.sendkey(f"shift-{ch.lower()}")
            else:
                self.sendkey(ch)
            time.sleep(0.02)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    action, rest = sys.argv[1], sys.argv[2:]
    q = QMP()

    if action == "screenshot":
        path = os.path.abspath(rest[0] if rest else "screen.png")
        q.cmd("screendump", filename=path, format="png")
        print(path)
    elif action == "key":
        for k in rest:
            q.sendkey(k)
        print("sent:", " ".join(rest))
    elif action == "type":
        q.type(rest[0])
        print("typed", len(rest[0]), "chars")
    elif action == "status":
        print(json.dumps(q.cmd("query-status")))
    elif action == "raw":
        payload = json.loads(rest[0])
        print(json.dumps(q.cmd(payload["execute"], **payload.get("arguments", {}))))
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
