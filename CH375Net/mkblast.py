#!/usr/bin/env python3
"""Blast UDP datagrams whose payload states where it belongs.

CH375Net, StevenC & Claude.  Public domain (the Unlicense).

    python mkblast.py <dos-ip> [--port 9999] [--secs 120] [--rate 40]

The other half of USBVFY.  Every datagram carries its own sequence number
and a payload that is a pure function of absolute stream position, so the
DOS side can check every byte without any state, loss costs nothing, and
ordering does not matter.

    bytes 0..3    the magic 'UVFY'
    bytes 4..7    sequence number, little endian
    bytes 8..N    payload[i] = byte (G mod 4) of (G div 4)
                  where G = seq * PAYLOAD + (i - 8)

The magic earns its place: without it a datagram whose header arrived
corrupt is indistinguishable from a datagram that was never ours, and the
first real event hit exactly that. 84 foreign datagrams turned up on the
port during one run, so "unexpected sequence number" had two possible
meanings and no way to choose between them.

WHY A COUNTER AND NOT A RAMP

The ramp used everywhere else in this project repeats every 256 bytes,
which means a displacement is only ever knowable modulo 256: the fault
under investigation reads as "-64, or -320, or -576", and the entire
question of whether the CH375's 64-byte packet buffer is involved turns on
which.  A 32-bit counter of the word index has a period of four gigabytes,
so the misplaced word's own value names the offset it came from and the
displacement comes out exact.

WHY BLAST RATHER THAN REQUEST

Nothing has to be acknowledged, so the DOS box collects bursts as fast as
it can poll instead of waiting on a round trip.  The driver's ceiling is 31
reads of 64 bytes per timer tick, near 36 KB/s, against 16.8 measured over
HTTP -- so events arrive about twice as often per minute of testing.

The rate needs care in one direction only: sending far faster than the box
can drain just fills the adapter and is thrown away, which wastes nothing
but proves nothing either.  40 datagrams a second is about 56 KB/s, which
is comfortably above what the box can take and keeps it saturated.
"""

import argparse
import socket
import struct
import sys
import time

MAGIC = b'UVFY'
PAYLOAD = 1400 - 8


def body(seq):
    """The 1396 payload bytes belonging to this sequence number."""
    base = seq * PAYLOAD
    out = bytearray(PAYLOAD)
    for i in range(PAYLOAD):
        g = base + i
        out[i] = (g >> 2) >> (8 * (g & 3)) & 0xFF
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("host", help="the DOS box's address on the USB adapter")
    ap.add_argument("--port", type=int, default=9999)
    ap.add_argument("--secs", type=float, default=120)
    ap.add_argument("--rate", type=float, default=40,
                    help="datagrams per second (default 40, ~56 KB/s)")
    ap.add_argument("--corrupt-every", type=int, default=0, metavar="N",
                    help="deliberately damage 1 datagram in N, by planting "
                         "the real fault's signature: 4 bytes from -64 then "
                         "158 from +76. Proves the receiver can FAIL.")
    a = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
    # BROADCAST IS NOT OPTIONAL, and the reason is on the DOS side: nothing
    # there answers ARP while its stack holds only the IP handle, so this
    # machine's cache entry for the box lapses after a couple of minutes and
    # Windows quietly stops delivering unicast to it. Measured: 9 datagrams
    # arrived in 15 minutes out of ~40,000 sent. Aim this at the subnet
    # broadcast address and nothing needs resolving.
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    # The payload is expensive to build in Python and cheap to reuse, and it
    # only depends on the sequence number, so a window of them is
    # precomputed and cycled.  The DOS side keys everything off the sequence
    # number in the datagram, so reusing a window changes nothing about what
    # is being tested -- it just stops the sender being the bottleneck,
    # which would quietly turn a receive test into a Python benchmark.
    WINDOW = 256
    cache = [body(q) for q in range(WINDOW)]

    gap = 1.0 / a.rate
    end = time.time() + a.secs
    seq = 0
    sent = 0
    planted = 0
    nxt = time.time()
    print("blasting %s:%d for %.0fs at ~%.0f/s (%.1f KB/s)"
          % (a.host, a.port, a.secs, a.rate, a.rate * 1400 / 1024))
    try:
        while time.time() < end:
            pkt = MAGIC + struct.pack("<I", seq) + cache[seq % WINDOW]
            if a.corrupt_every and sent and sent % a.corrupt_every == 0:
                # Plant the signature the driver actually produces, so the
                # receiver has to detect and decode a KNOWN displacement.
                # An instrument that has not been shown able to fail is not
                # evidence, and this one was rewritten for speed.
                b = bytearray(pkt)
                o = 8 + 400
                b[o:o + 4] = bytes(pkt[o - 64:o - 60])
                b[o + 4:o + 162] = bytes(pkt[o + 80:o + 238])
                pkt = bytes(b)
                planted += 1
            try:
                s.sendto(pkt, (a.host, a.port))
                sent += 1
            except OSError as e:
                print("send failed: %s" % e)
                time.sleep(0.5)
            seq = (seq + 1) % WINDOW
            nxt += gap
            slack = nxt - time.time()
            if slack > 0:
                time.sleep(slack)
            else:
                nxt = time.time()
    except KeyboardInterrupt:
        pass
    print("sent %d datagrams (%.1f MB), %d deliberately corrupted"
          % (sent, sent * 1400 / 1048576.0, planted))


if __name__ == "__main__":
    main()
