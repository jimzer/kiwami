#!/usr/bin/env python3
"""Drive the VM's serial console over a unix socket.

  console.py expect "nixos@nixos"        wait for text to appear
  console.py run "uname -m"              run a command, print stdout, exit with its code
  console.py send "raw text no newline"
  console.py login                       log in at the getty prompt
  console.py tail                        dump what's currently buffered
"""
import os
import pathlib
import re
import socket
import sys
import time
import uuid

SOCK = os.environ.get("SERIAL_SOCK", "/tmp/kiwami-serial.sock")
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[=>P][^\x1b]*\\?")


def clean(b: bytes) -> str:
    return ANSI.sub("", b.decode("utf-8", "replace")).replace("\r", "")


class Console:
    def __init__(self, path=SOCK, seed_log=True):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.s.settimeout(0.3)
        self.buf = b""
        # Seed from the chardev logfile: anything QEMU emitted before we
        # connected is not replayed on the socket, only recorded there.
        if seed_log:
            log = pathlib.Path(os.environ.get("SERIAL_LOG", "serial.log"))
            if log.exists():
                self.buf = log.read_bytes()[-262144:]

    def _pump(self):
        try:
            chunk = self.s.recv(65536)
            if chunk:
                self.buf += chunk
        except socket.timeout:
            pass
        return self.buf

    def expect(self, needle, timeout=120):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if needle in clean(self._pump()):
                return True
            time.sleep(0.1)
        return False

    def send(self, text):
        self.s.sendall(text.encode())

    def sendline(self, text=""):
        self.send(text + "\n")

    def login(self, user="nixos", password="kiwami", timeout=60):
        """Log in if the console is at a getty prompt. Idempotent.

        Every step clears the buffer first: expect() scans the whole
        accumulated buffer, which is seeded from serial.log, so stale text
        (an earlier "Password:") would match instantly and desynchronise
        the whole sequence.
        """
        self.buf = b""
        self.sendline("")
        time.sleep(1)
        if "login:" not in clean(self._pump())[-500:]:
            self.buf = b""
            return self.run("true", timeout=30)[0] == 0

        self.buf = b""
        self.sendline(user)
        if not self.expect("assword", timeout=15):
            return False

        self.buf = b""
        self.sendline(password)
        if not self.expect(f"{user}@", timeout=timeout):
            return False

        self.buf = b""
        return self.run("true", timeout=30)[0] == 0

    def run(self, cmd, timeout=600):
        """Run cmd, return (exit_code, output). Uses a nonce sentinel."""
        nonce = uuid.uuid4().hex[:12]
        start, end = f"__S{nonce}__", f"__E{nonce}__"
        self.buf = b""
        # Wrap in a subshell: a command ending in "&" makes the naive
        # "cmd; echo ..." form a syntax error ("& ;"), while "( cmd & )"
        # is valid. Note this means cd/exports do not persist between
        # run() calls - use send() for stateful things like "sudo -i".
        # Quote the nonce inside the command so the terminal's ECHO of this
        # line does not itself contain the literal sentinels - otherwise
        # expect() fires on the echoed command and we parse before the
        # command has actually run.
        self.sendline(f'echo __S"{nonce}"__; ( {cmd} ); echo __E"{nonce}"__$?')
        if not self.expect(end, timeout):
            return 124, clean(self.buf)
        text = clean(self.buf)
        # last occurrence = the echoed output, not the echoed command line
        body = text.rsplit(start, 1)[-1]
        out, _, tail = body.rpartition(end)
        code = re.match(r"(\d+)", tail.strip())
        return (int(code.group(1)) if code else -1), out.strip("\n")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    action = sys.argv[1]
    arg = sys.argv[2] if len(sys.argv) > 2 else ""
    c = Console()

    if action == "login":
        ok = c.login()
        print("LOGGED_IN" if ok else "LOGIN_FAILED")
        return 0 if ok else 1
    if action == "expect":
        ok = c.expect(arg, timeout=int(os.environ.get("TIMEOUT", "120")))
        print("FOUND" if ok else "TIMEOUT")
        return 0 if ok else 1
    if action == "run":
        # A fresh boot leaves the serial console at a getty prompt; without
        # this, run() would block until timeout waiting for a shell that
        # is not listening. login() is idempotent and cheap.
        c.login()
        code, out = c.run(arg, timeout=int(os.environ.get("TIMEOUT", "180")))
        print(out)
        return code
    if action == "send":
        c.sendline(arg)
        time.sleep(0.5)
        print(clean(c._pump())[-2000:])
        return 0
    if action == "tail":
        time.sleep(1)
        print(clean(c._pump())[-4000:])
        return 0
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
