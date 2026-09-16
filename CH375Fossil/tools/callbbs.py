"""Dial the DOS box's BBS and put it through everything a real BBS would do.

Three calls:
  1. the full battery, including a 128 KB endurance transfer
  2. a caller who starts a download and vanishes without warning
  3. a caller still connected when the BBS abandons the call, so the
     driver's unload path has to clean up a live connection

The telnet filter is STATEFUL and follows RFC 854's loop-prevention rule.
Both matter: the binary tests carry one 0xFF per 256 bytes, each doubled on
the wire, and a doubled pair straddling a packet boundary would be
mis-parsed by a filter that starts fresh on every recv; and answering an
acknowledgement with another acknowledgement is what produced thirty
thousand segments for two kilobytes of real data.
"""
import socket
import struct
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.50.66"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 2323

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240
BINARY, ECHO, SGA = 0, 1, 3

CR = chr(13)

failures = []


def fail(msg):
    failures.append(msg)
    print("   FAIL: " + msg)


class Line:
    """A telnet-aware byte stream over one socket."""

    def __init__(self, sock):
        self.s = sock
        self.plain = bytearray()
        self.state = 0
        self.cmd = 0
        self.trace = None
        self.said_us = set()
        self.said_them = set()

    def _feed(self, data):
        out = self.plain
        for b in data:
            if self.state == 0:
                if b == IAC:
                    self.state = 1
                else:
                    out.append(b)
            elif self.state == 1:
                if b == IAC:
                    out.append(IAC)
                    self.state = 0
                elif b == SB:
                    self.state = 3
                elif b in (WILL, WONT, DO, DONT):
                    self.cmd = b
                    self.state = 2
                else:
                    self.state = 0
            elif self.state == 2:
                self._answer(self.cmd, b)
                self.state = 0
            elif self.state == 3:
                if b == IAC:
                    self.state = 4
            elif self.state == 4:
                self.state = 0 if b == SE else 3

    def _answer(self, cmd, opt):
        # RFC 854: never acknowledge an acknowledgement.
        if cmd == DO:
            if opt in self.said_us:
                return
            self.said_us.add(opt)
            reply = WILL if opt in (BINARY, SGA) else WONT
        elif cmd == WILL:
            if opt in self.said_them:
                return
            self.said_them.add(opt)
            reply = DO if opt in (BINARY, ECHO, SGA) else DONT
        else:
            return
        self.s.sendall(bytes([IAC, reply, opt]))

    def _pump(self, timeout):
        self.s.settimeout(timeout)
        try:
            chunk = self.s.recv(16384)
        except socket.timeout:
            return False
        if not chunk:
            return False
        if self.trace is not None:
            self.trace.append((time.time(), len(chunk)))
        self._feed(chunk)
        return True

    def read_exact(self, n, budget=90.0):
        end = time.time() + budget
        while len(self.plain) < n and time.time() < end:
            self._pump(2.0)
        got = bytes(self.plain[:n])
        del self.plain[:len(got)]
        return got

    def read_line(self, budget=60.0):
        end = time.time() + budget
        while time.time() < end:
            i = self.plain.find(b"\n")
            if i >= 0:
                line = bytes(self.plain[:i]).rstrip(b"\r")
                del self.plain[:i + 1]
                return line.decode("latin-1")
            self._pump(2.0)
        return None

    def read_until(self, needle, budget=90.0):
        end = time.time() + budget
        seen = []
        while time.time() < end:
            line = self.read_line(budget=5.0)
            if line is None:
                continue
            seen.append(line)
            if needle in line:
                return seen
        return seen

    def wait_header(self, needle, budget=40.0):
        end = time.time() + budget
        while time.time() < end:
            line = self.read_line(budget=5.0)
            if line is None:
                continue
            if needle in line:
                return line
        return None

    def send_text(self, s):
        self.s.sendall(s.encode("latin-1"))

    def send_raw(self, data):
        self.s.sendall(data.replace(b"\xff", b"\xff\xff"))


def pattern(n):
    return bytes((i & 0xFF) for i in range(n))


def connect(number):
    deadline = time.time() + 100
    while True:
        try:
            sock = socket.create_connection((HOST, PORT), timeout=6)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            return sock
        except (OSError, socket.timeout):
            if time.time() > deadline:
                fail("no answer on call %d" % number)
                return None
            time.sleep(1.0)


def do_housekeeping(ln):
    print("--- [H] housekeeping ---")
    ln.send_text("H" + CR)
    for line in ln.read_until("HOUSEKEEPING", budget=60.0):
        if line.strip():
            print("   " + line)


def check_block(data, want, label):
    if len(data) != want:
        fail("%s: short, %d of %d bytes" % (label, len(data), want))
        return False
    expect = pattern(want)
    if data == expect:
        print("   ALL %d BYTES BYTE-EXACT, including 0xFF and 0x00" % want)
        return True
    bad = [i for i in range(want) if data[i] != expect[i]]
    fail("%s: %d bytes wrong, first at offset %d (got %02X want %02X)"
         % (label, len(bad), bad[0], data[bad[0]], expect[bad[0]]))
    return False


def timed_read(ln, want, budget):
    ln.trace = []
    t0 = time.time()
    data = ln.read_exact(want, budget=budget)
    dt = time.time() - t0
    tr, ln.trace = ln.trace, None
    if tr and len(tr) > 1:
        sizes = [n for _, n in tr]
        gaps = sorted(tr[i][0] - tr[i - 1][0] for i in range(1, len(tr)))
        print("   arrivals: %d chunks, mean %d bytes, largest %d"
              % (len(sizes), sum(sizes) // len(sizes), max(sizes)))
        print("   gaps: median %.0f ms, worst %.0f ms"
              % (gaps[len(gaps) // 2] * 1000, gaps[-1] * 1000))
    if dt > 0 and data:
        print("   %d bytes in %.1fs -- %.0f bytes/s"
              % (len(data), dt, len(data) / dt))
    return data


def do_download(ln):
    print("--- [B] binary download, 8-bit clean ---")
    ln.send_text("B" + CR)
    hdr = ln.wait_header("BEGIN BINARY")
    if hdr is None:
        fail("no BEGIN BINARY header")
        return
    want = int(hdr.split()[-1])
    data = timed_read(ln, want, 120.0)
    check_block(data, want, "download")
    ln.read_until("END BINARY", budget=30.0)


def do_large(ln):
    print("--- [L] 128 KB endurance transfer ---")
    ln.send_text("L" + CR)
    hdr = ln.wait_header("BEGIN LARGE", budget=60.0)
    if hdr is None:
        fail("no BEGIN LARGE header")
        return
    want = int(hdr.split()[-1])
    print("   expecting %d bytes" % want)
    data = timed_read(ln, want, 300.0)
    check_block(data, want, "large transfer")
    ln.read_until("END LARGE", budget=60.0)


def do_upload(ln):
    print("--- [U] binary upload, 8-bit clean ---")
    ln.send_text("U" + CR)
    hdr = ln.wait_header("SEND")
    if hdr is None:
        fail("no SEND header")
        return
    n = int(hdr.split()[-1])
    blob = pattern(n)
    print("   sending %d bytes, containing %d 0xFF to be doubled"
          % (n, blob.count(b"\xff")))
    for off in range(0, n, 256):
        ln.send_raw(blob[off:off + 256])
        time.sleep(0.02)
    got = ln.read_until("UPLOAD", budget=90.0)
    for line in got:
        if "UPLOAD" in line:
            print("   " + line)
    if not any("UPLOAD OK" in l for l in got):
        fail("upload was not accepted")


def read_to_close(sock, ln, budget):
    sock.settimeout(budget)
    try:
        while True:
            chunk = sock.recv(8192)
            if not chunk:
                return True
            ln._feed(chunk)
    except socket.timeout:
        return False
    except OSError:
        return True


def call_full(number, large):
    print("=========== call %d ===========" % number)
    t0 = time.time()
    sock = connect(number)
    if sock is None:
        return
    print("carrier in %.2fs" % (time.time() - t0))
    ln = Line(sock)
    greet = ln.read_until("Command:", budget=40.0)
    if not any("FOSBBS" in l for l in greet):
        fail("no greeting on call %d" % number)
    for line in greet:
        if "answering call" in line:
            print("   " + line.strip())

    do_housekeeping(ln)
    do_download(ln)
    do_upload(ln)
    if large:
        do_large(ln)

    print("--- [G] goodbye ---")
    ln.send_text("G" + CR)
    closed = read_to_close(sock, ln, 25.0)
    text = bytes(ln.plain).decode("latin-1")
    if "Goodbye. Dropping carrier." in text:
        print("   the closing line arrived COMPLETE")
    else:
        fail("closing line truncated on call %d" % number)
    if closed:
        print("   far end closed the connection")
    else:
        fail("far end did not close on call %d" % number)
    sock.close()
    print("   call %d lasted %.1fs" % (number, time.time() - t0))


def call_vanish(number):
    """Start a download and disappear, the way a caller closing their
    terminal does."""
    print("=========== call %d: caller vanishes mid-transfer ==========="
          % number)
    sock = connect(number)
    if sock is None:
        return
    ln = Line(sock)
    if not any("FOSBBS" in l for l in ln.read_until("Command:", budget=40.0)):
        fail("no greeting on call %d" % number)
        sock.close()
        return
    ln.send_text("B" + CR)
    got = ln.read_exact(1024, budget=30.0)
    print("   read %d bytes, then pulling the plug" % len(got))
    # SO_LINGER with a zero timeout makes close() send RST rather than FIN.
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                    struct.pack("hh", 1, 0))
    sock.close()
    print("   connection reset without warning")


def call_abandon(number):
    """Stay connected while the BBS walks away without hanging up, so the
    driver's unload path has to clean up a live connection."""
    print("=========== call %d: the BBS abandons the call ==========="
          % number)
    sock = connect(number)
    if sock is None:
        return
    ln = Line(sock)
    greet = ln.read_until("Command:", budget=40.0)
    if not any("FOSBBS" in l for l in greet):
        fail("no greeting on call %d" % number)
        sock.close()
        return
    for line in greet:
        if "answering call" in line:
            print("   " + line.strip())
    ln.send_text("X" + CR)
    for line in ln.read_until("Abandoning", budget=30.0):
        if "Abandoning" in line:
            print("   " + line.strip())
    print("   the BBS is gone; the line is still open and the driver still")
    print("   holds its handles. Waiting for the unload to clean up...")
    t0 = time.time()
    closed = read_to_close(sock, ln, 90.0)
    if closed:
        print("   the connection was closed after %.1fs" % (time.time() - t0))
    else:
        fail("nothing closed the abandoned connection")
    sock.close()


def main():
    # Separate jobs, because the abandon test halts the BBS and would
    # suppress its own end-of-run summary if it shared one.
    mode = sys.argv[3] if len(sys.argv) > 3 else "cover"
    if mode == "cover":
        call_full(1, large=True)
        time.sleep(2.0)
        call_vanish(2)
    elif mode == "abandon":
        call_abandon(3)
    else:
        print("unknown mode: " + mode)
        sys.exit(2)

    print("===============================")
    if failures:
        print("FAILURES (%d):" % len(failures))
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("ALL CHECKS PASSED")


if __name__ == "__main__":
    main()
