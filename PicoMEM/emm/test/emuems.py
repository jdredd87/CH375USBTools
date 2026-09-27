"""emuems.py -- run a PMEMM build in an 8086 emulator and put it through
the same behaviour test as EMSTEST.EXE.  StevenC & Claude, 2026.
Public domain (the Unlicense).

    python emuems.py DRIVER.SYS [more.SYS ...]

The driver is the real binary (the load image of PMEMM.EXE -- see
cmpimg.py/--sys in build.cmd): it is initialised the way DOS initialises a
CONFIG.SYS driver and then called through INT 67h exactly as a program
would.  The PicoMEM's EMS hardware is modelled as four 16 KB windows at
E000h whose page registers are I/O ports: an OUT maps a page of a 4 MB
backing store into that window, so two windows showing one page really
are the same memory, as on the card.

What this proves and what it does not: it runs the driver's actual
instructions, so a wrong result, a clobbered register or a window left
mapped wrong shows up here exactly as it would on the machine.  It says
nothing about SPEED, and nothing about the card's own timing -- that is
EMSTEST /B on hardware.  Unicorn emulates a 386-class core in 16-bit mode,
so it will also execute 186 instructions an 8086 would not: the 8086
paths are what the default run exercises (the driver picks at run time).

With two or more drivers it prints each transcript and a diff.
"""
import ctypes, struct, sys, zlib
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR, UC_HOOK_INSN, UcError
from unicorn.x86_const import *

DRVSEG = 0x1000          # where the driver image is loaded
FRAME = 0xE000           # page frame segment the "card" reports
EMSPORT = 0x268          # page register base the "card" reports
PAGES = 256              # backing store pages (0..255, FF = "disabled")
STUB = 0x0600            # linear address of the call stubs
REQ = 0x0700             # request header
CMDL = 0x0740            # command line
STACKSEG = 0x9000

REGS = dict(ax=UC_X86_REG_AX, bx=UC_X86_REG_BX, cx=UC_X86_REG_CX, dx=UC_X86_REG_DX,
            si=UC_X86_REG_SI, di=UC_X86_REG_DI, bp=UC_X86_REG_BP, ds=UC_X86_REG_DS,
            es=UC_X86_REG_ES)


class Machine:
    def __init__(self, image, cmdline=b'PMEMM.SYS /n', cpu186=False):
        self.out = []
        self.store = (ctypes.c_ubyte * (PAGES * 16384))()
        self.bank = [0xFF] * 4
        self.cpu186 = cpu186
        uc = self.uc = Uc(UC_ARCH_X86, UC_MODE_16)
        uc.mem_map(0, 0xE0000)                     # everything below the frame
        for w in range(4):
            self._map_window(w, 0xFF)
        uc.mem_map(0xF0000, 0x10000)
        uc.mem_write(DRVSEG * 16, image)
        uc.hook_add(UC_HOOK_INTR, self._intr)
        uc.hook_add(UC_HOOK_INSN, self._out, None, 1, 0, UC_X86_INS_OUT)
        uc.hook_add(UC_HOOK_INSN, self._in, None, 1, 0, UC_X86_INS_IN)
        self.stop_at = None
        self.init_driver(cmdline)

    # ---- the card
    def _map_window(self, w, page):
        base = (FRAME * 16) + w * 16384
        try:
            self.uc.mem_unmap(base, 16384)
        except UcError:
            pass
        addr = ctypes.addressof(self.store) + page * 16384
        self.uc.mem_map_ptr(base, 16384, 3, addr)
        self.bank[w] = page

    def _out(self, uc, port, size, value, ud):
        if EMSPORT <= port < EMSPORT + 4:
            self._map_window(port - EMSPORT, value & 0xFF)
        # port 61h (speaker/parity) and anything else: ignored

    def _in(self, uc, port, size, ud):
        if EMSPORT <= port < EMSPORT + 4:
            return self.bank[port - EMSPORT]
        if port == 0x61:
            return 0
        return 0xFF

    # ---- interrupts: INT 67h goes through the real IVT; DOS/BIOS are faked
    def _intr(self, uc, intno, ud):
        ip = uc.reg_read(UC_X86_REG_IP)          # already past the INT
        cs = uc.reg_read(UC_X86_REG_CS)
        # find the INT number: unicorn reports it as intno
        if intno == 0x67 or intno == 0x2F and False:
            fl = uc.reg_read(UC_X86_REG_FLAGS)
            sp = uc.reg_read(UC_X86_REG_SP) - 6
            ss = uc.reg_read(UC_X86_REG_SS)
            uc.mem_write(ss * 16 + sp, struct.pack('<HHH', ip, cs, fl))
            uc.reg_write(UC_X86_REG_SP, sp)
            uc.reg_write(UC_X86_REG_FLAGS, fl & ~0x0300)
            off, seg = struct.unpack('<HH', bytes(uc.mem_read(intno * 4, 4)))
            uc.reg_write(UC_X86_REG_CS, seg)
            uc.reg_write(UC_X86_REG_IP, off)
            return
        ax = uc.reg_read(UC_X86_REG_AX)
        if intno == 0x13 and ax == 0x6000:
            uc.reg_write(UC_X86_REG_DX, 0xAA55)
        elif intno == 0x13 and ax == 0x6001:
            uc.reg_write(UC_X86_REG_CX, EMSPORT)
            uc.reg_write(UC_X86_REG_DX, FRAME)
        elif intno == 0x21 and (ax >> 8) == 9:
            ds = uc.reg_read(UC_X86_REG_DS); dx = uc.reg_read(UC_X86_REG_DX)
            m = bytes(uc.mem_read(ds * 16 + dx, 400))
            self.out.append(m[:m.index(b'$')].decode('latin1'))
        elif intno == 0x16:
            uc.reg_write(UC_X86_REG_FLAGS, uc.reg_read(UC_X86_REG_FLAGS) | 0x40)  # ZF: no key
        else:
            raise RuntimeError('unexpected INT %02Xh AX=%04X at %04X:%04X' % (intno, ax, cs, ip))

    # ---- running code
    def run(self, seg, off, stop_lin, limit=20_000_000):
        self.uc.reg_write(UC_X86_REG_CS, seg)
        self.uc.reg_write(UC_X86_REG_IP, off)
        self.uc.emu_start(seg * 16 + off, stop_lin, count=limit)
        ip = self.uc.reg_read(UC_X86_REG_CS) * 16 + self.uc.reg_read(UC_X86_REG_IP)
        if ip != stop_lin:
            raise RuntimeError('did not come back: stopped at %05X' % ip)

    def init_driver(self, cmdline):
        uc = self.uc
        strat, intr = struct.unpack_from('<HH', bytes(uc.mem_read(DRVSEG * 16 + 6, 4)))
        uc.mem_write(CMDL, cmdline + b'\r\n')
        req = bytearray(26); req[0] = 26; req[2] = 0
        struct.pack_into('<HH', req, 18, CMDL, 0)
        uc.mem_write(REQ, bytes(req))
        # call far strat ; call far intr ; hlt
        stub = b'\x9a' + struct.pack('<HH', strat, DRVSEG) + b'\x9a' + struct.pack('<HH', intr, DRVSEG) + b'\xf4'
        uc.mem_write(STUB, stub)
        uc.reg_write(UC_X86_REG_SS, STACKSEG); uc.reg_write(UC_X86_REG_SP, 0xFFF0)
        uc.reg_write(UC_X86_REG_ES, 0); uc.reg_write(UC_X86_REG_BX, REQ)
        uc.reg_write(UC_X86_REG_DS, 0)
        self.run(0, STUB, STUB + 10)
        status, = struct.unpack_from('<H', bytes(uc.mem_read(REQ + 3, 2)))
        brk_off, brk_seg = struct.unpack_from('<HH', bytes(uc.mem_read(REQ + 14, 4)))
        self.resident = (brk_seg - DRVSEG) * 16 + brk_off
        self.init_status = status
        # the caller stub for INT 67h
        uc.mem_write(STUB + 0x20, b'\xcd\x67\xf4')

    def call(self, ax, **r):
        uc = self.uc
        for k in REGS:
            uc.reg_write(REGS[k], r.get(k, 0 if k not in ('ds', 'es') else 0x2000))
        uc.reg_write(UC_X86_REG_AX, ax)
        uc.reg_write(UC_X86_REG_SS, STACKSEG); uc.reg_write(UC_X86_REG_SP, 0xFFF0)
        uc.reg_write(UC_X86_REG_FLAGS, 0x0202)
        before = {k: uc.reg_read(REGS[k]) for k in REGS}
        self.run(0, STUB + 0x20, STUB + 0x22)
        after = {k: uc.reg_read(REGS[k]) for k in REGS}
        after['ax'] = uc.reg_read(UC_X86_REG_AX)
        after['sp'] = uc.reg_read(UC_X86_REG_SP)
        after['flags'] = uc.reg_read(UC_X86_REG_FLAGS)
        self.last_before = before
        return after

    # ---- memory helpers (all in segment 2000h, the "program's data")
    def rd(self, seg, off, n):
        return bytes(self.uc.mem_read(seg * 16 + off, n))

    def wr(self, seg, off, data):
        self.uc.mem_write(seg * 16 + off, bytes(data))


# ---------------------------------------------------------------- the test
DATA = 0x2000     # the test program's data segment
PAIRS = 0x0000    # 32 bytes
MV = 0x0040       # move structure
NAMES = 0x0080
BUFA = 0x3000     # separate segments: 48 KB each
BUFB = 0x4000 + 0x0C00


class Test:
    def __init__(self, m):
        self.m = m
        self.lines = []
        self.fails = 0

    def T(self, s):
        self.lines.append(s)

    def must(self, ok, what):
        if not ok:
            self.fails += 1
            self.T('  ** FAILED: ' + what)

    def ems(self, ax, **r):
        res = self.m.call(ax, **r)
        # registers the function does not return must come back unchanged
        self.r = res
        return res

    def st(self):
        return 'AH=%02X' % (self.r['ax'] >> 8)

    def winseg(self, p):
        return FRAME + p * 0x400

    def fillwin(self, p, v):
        s = self.winseg(p)
        self.m.wr(s, 0, struct.pack('<H', v) * 0x2000)
        self.m.wr(s, 0, bytes([(v & 0xFF) ^ 0x5A]))

    def checkwin(self, p, v):
        d = self.m.rd(self.winseg(p), 0, 16384)
        exp = bytearray(struct.pack('<H', v) * 0x2000); exp[0] = (v & 0xFF) ^ 0x5A
        return d == bytes(exp)

    def tag(self, h, p):
        return ((h << 8) ^ (p * 37) ^ 0xA5C3) & 0xFFFF

    def map(self, phys, log, h):
        return self.ems(0x4400 | phys, bx=log, dx=h)['ax'] >> 8

    def run(self):
        self.basics(); self.maps(); self.map50(); self.mapsave(); self.realloc()
        self.moves(); self.names(); self.jumpcall(); self.free()
        crc = zlib.crc32('\n'.join(self.lines).encode())
        self.T('--- %d data checks failed, transcript crc %08X ---' % (self.fails, crc))
        return self.lines

    def basics(self):
        self.ems(0x4000); self.T('40 status          ' + self.st())
        r = self.ems(0x4100); self.T('41 frame           %s seg=%04X' % (self.st(), r['bx']))
        r = self.ems(0x4200); self.total, self.free0 = r['dx'], r['bx']
        self.T('42 pages           %s total=%d' % (self.st(), self.total))
        r = self.ems(0x4600); self.T('46 version         %s AL=%02X' % (self.st(), r['ax'] & 0xFF))
        self.ems(0x4B00); self.T('4B handles         ' + self.st())
        self.ems(0x4300, bx=0); self.T('43 alloc 0         ' + self.st())
        self.ems(0x4300, bx=self.total + 1); self.T('43 alloc total+1   ' + self.st())
        self.ems(0x3F00); self.T('3F bad function    ' + self.st())
        self.ems(0x5E00); self.T('5E bad function    ' + self.st())
        self.ems(0xFF00); self.T('FF bad function    ' + self.st())

    def maps(self):
        r = self.ems(0x4300, bx=64); self.H1 = r['dx']; self.T('43 alloc 64        ' + self.st())
        r = self.ems(0x4300, bx=3); self.H2 = r['dx']; self.T('43 alloc 3         ' + self.st())
        H1, H2 = self.H1, self.H2
        r = self.ems(0x4B00); self.T('4B handles         %s BX=%d' % (self.st(), r['bx'] - 1))
        r = self.ems(0x4C00, dx=H1); self.T('4C pages H1        %s BX=%d' % (self.st(), r['bx']))
        ok = True
        for p in range(64):
            if self.map(p & 3, p, H1): ok = False
            self.fillwin(p & 3, self.tag(H1, p))
        for p in range(3):
            self.map(p, p, H2); self.fillwin(p, self.tag(H2, p))
        self.must(ok, '44 mapping while filling')
        for p in range(63, -1, -1):
            ph = (p + 1) & 3
            if self.map(ph, p, H1): ok = False
            if not self.checkwin(ph, self.tag(H1, p)): ok = False
        for p in range(3):
            self.map(3 - p, p, H2)
            if not self.checkwin(3 - p, self.tag(H2, p)): ok = False
        self.must(ok, '44 read back through another window')
        self.T('44 fill+verify     67 pages %d' % ok)
        # registers: 44h must preserve everything but AX
        r = self.ems(0x4401, bx=7, dx=H1, cx=0x1234, si=0x5678, di=0x9ABC, bp=0x1111, ds=0x2222, es=0x3333)
        keep = all(r[k] == v for k, v in dict(bx=7, dx=H1, cx=0x1234, si=0x5678, di=0x9ABC, bp=0x1111, ds=0x2222, es=0x3333).items())
        self.T('44 preserves regs  %d sp=%04X' % (keep, r['sp']))
        self.must(keep, '44 clobbered a register')
        self.must(self.checkwin(1, self.tag(H1, 7)), '44 with regs')
        for nm, a in (('44 phys 4        ', (4, 0, H1)), ('44 phys 255      ', (255, 0, H1)),
                      ('44 log out of rng', (0, 64, H1)), ('44 log 255 on H2 ', (0, 255, H2)),
                      ('44 log 256+1 H1  ', (0, 257, H1)), ('44 log 0x8001 H1 ', (0, 0x8001, H1)),
                      ('44 handle 99     ', (0, 0, 99)), ('44 handle 63 free', (0, 0, 63)),
                      ('44 handle 0x100  ', (0, 0, 0x100))):
            self.T('%s  AH=%02X' % (nm, self.map(*a)))
        self.T('44 unmap           AH=%02X' % self.map(2, 0xFFFF, H1))
        self.T('44 remap same      AH=%02X %02X' % (self.map(1, 5, H1), self.map(1, 5, H1)))
        self.must(self.checkwin(1, self.tag(H1, 5)), '44 remap same page')
        # the sequence that the same-page shortcut could get wrong: same page
        # number, different handle
        self.map(0, 1, H2); self.map(0, 1, H1)
        self.must(self.checkwin(0, self.tag(H1, 1)), '44 same page number, other handle')
        self.T('44 other handle    %d' % self.checkwin(0, self.tag(H1, 1)))

    def pairs(self, lst):
        self.m.wr(DATA, PAIRS, b''.join(struct.pack('<HH', a, b) for a, b in lst))

    def map50(self):
        H1 = self.H1
        self.pairs([(10 + i, 3 - i) for i in range(4)])
        self.ems(0x5000, cx=4, dx=H1, ds=DATA, si=PAIRS)
        ok = all(self.checkwin(3 - i, self.tag(H1, 10 + i)) for i in range(4))
        self.T('50/00 map 4        %s %d' % (self.st(), ok)); self.must(ok, '50/00')
        self.pairs([(40 + i, self.winseg(i)) for i in range(4)])
        self.ems(0x5001, cx=4, dx=H1, ds=DATA, si=PAIRS)
        ok = all(self.checkwin(i, self.tag(H1, 40 + i)) for i in range(4))
        self.T('50/01 map 4 by seg %s %d' % (self.st(), ok)); self.must(ok, '50/01')
        for nm, sub, lst, n, h in (('50/00 phys 4     ', 0, [(1, 4)], 1, H1),
                                   ('50/01 bad seg    ', 1, [(1, 0xD000)], 1, H1),
                                   ('50/00 log range  ', 0, [(70, 0)], 1, H1),
                                   ('50/00 log 257    ', 0, [(257, 0)], 1, H1),
                                   ('50/00 count 5    ', 0, [(1, 0)] * 5, 5, H1),
                                   ('50/00 count 0    ', 0, [], 0, H1),
                                   ('50/00 handle 99  ', 0, [(1, 0)], 1, 99),
                                   ('50/02            ', 2, [(1, 0)], 1, H1),
                                   ('50/00 unmap      ', 0, [(0xFFFF, 1)], 1, H1)):
            self.pairs(lst); self.ems(0x5000 | sub, cx=n, dx=h, ds=DATA, si=PAIRS)
            self.T('%s  %s' % (nm, self.st()))
        # partial failure: second entry bad -- what state is left?
        for i in range(4): self.map(i, i, H1)
        self.pairs([(20, 0), (99, 1)]); self.ems(0x5000, cx=2, dx=H1, ds=DATA, si=PAIRS)
        self.T('50/00 2nd bad      %s win0=%d' % (self.st(), self.checkwin(0, self.tag(H1, 20))))

    def mapsave(self):
        H1, H2 = self.H1, self.H2
        for i in range(4): self.map(i, 20 + i, H1)
        r = self.ems(0x4E03); self.T('4E/03 size         %s AL=%d' % (self.st(), r['ax'] & 0xFF))
        self.m.wr(BUFA, 0, b'\xee' * 256)
        self.ems(0x4E00, es=BUFA, di=0)
        saved = self.m.rd(BUFA, 0, 64)
        self.T('4E/00 get          %s crc=%08X' % (self.st(), zlib.crc32(saved)))
        for i in range(4): self.map(i, 30 + i, H1)
        self.ems(0x4E01, ds=BUFA, si=0)
        ok = all(self.checkwin(i, self.tag(H1, 20 + i)) for i in range(4))
        self.T('4E/01 set          %s %d' % (self.st(), ok)); self.must(ok, '4E/01')
        for i in range(4): self.map(i, 50 + i, H1)
        self.ems(0x4E02, ds=BUFA, si=0, es=BUFB, di=0)
        ok = all(self.checkwin(i, self.tag(H1, 20 + i)) for i in range(4))
        self.T('4E/02 get+set      %s %d crc=%08X' % (self.st(), ok, zlib.crc32(self.m.rd(BUFB, 0, 64))))
        self.must(ok, '4E/02')
        bad = bytearray(saved); bad[2] ^= 1; self.m.wr(BUFB, 0, bad)
        self.ems(0x4E01, ds=BUFB, si=0); self.T('4E/01 corrupt      ' + self.st())
        self.ems(0x4E04); self.T('4E/04              ' + self.st())
        for i in range(4): self.map(i, 60 + i, H1)
        self.ems(0x4700, dx=H1); self.T('47 save H1         ' + self.st())
        self.ems(0x4700, dx=H1); self.T('47 save H1 again   ' + self.st())
        for i in range(4): self.map(i, i, H1)
        self.ems(0x4800, dx=H2); self.T('48 restore H2 none ' + self.st())
        self.ems(0x4800, dx=H1)
        ok = all(self.checkwin(i, self.tag(H1, 60 + i)) for i in range(4))
        self.T('48 restore H1      %s %d' % (self.st(), ok)); self.must(ok, '48')
        self.ems(0x4800, dx=H1); self.T('48 restore again   ' + self.st())
        self.ems(0x4700, dx=99); self.T('47 handle 99       ' + self.st())
        # all five save slots, then one more
        hs = []
        for i in range(6):
            r = self.ems(0x4300, bx=1); hs.append(r['dx'])
            self.ems(0x4700, dx=r['dx']); self.T('47 save slot %d     %s' % (i, self.st()))
        for h in hs:
            self.ems(0x4800, dx=h); self.ems(0x4500, dx=h)
        r = self.ems(0x4F02, bx=2); self.T('4F/02 size 2       %s AL=%d' % (self.st(), r['ax'] & 0xFF))
        self.ems(0x4F02, bx=5); self.T('4F/02 size 5       ' + self.st())
        for i in range(4): self.map(i, 8 + i, H1)
        self.m.wr(DATA, PAIRS, struct.pack('<HHH', 2, self.winseg(1), self.winseg(3)))
        self.ems(0x4F00, ds=DATA, si=PAIRS, es=BUFA, di=0)
        self.T('4F/00 get 2        %s crc=%08X' % (self.st(), zlib.crc32(self.m.rd(BUFA, 0, 20))))
        self.map(1, 0, H1); self.map(3, 0, H1)
        self.ems(0x4F01, ds=BUFA, si=0)
        ok = self.checkwin(1, self.tag(H1, 9)) and self.checkwin(3, self.tag(H1, 11))
        self.T('4F/01 set 2        %s %d' % (self.st(), ok)); self.must(ok, '4F/01')

    def realloc(self):
        H1, H2 = self.H1, self.H2
        free0 = self.ems(0x4200)['bx']
        r = self.ems(0x5100, dx=H2, bx=10); self.T('51 H2 3->10        %s BX=%d' % (self.st(), r['bx']))
        self.T('  free delta %d' % (free0 - self.ems(0x4200)['bx']))
        ok = True
        for p in range(3):
            self.map(0, p, H2)
            if not self.checkwin(0, self.tag(H2, p)): ok = False
        for p in range(3, 10):
            if self.map(p & 3, p, H2): ok = False
            self.fillwin(p & 3, self.tag(H2, p))
        for p in range(10):
            self.map(0, p, H2)
            if not self.checkwin(0, self.tag(H2, p)): ok = False
        self.T('  kept+new pages %d' % ok); self.must(ok, '51 grow')
        ok = all((self.map(1, p, H1) == 0 and self.checkwin(1, self.tag(H1, p))) for p in range(64))
        self.T('  H1 intact %d' % ok); self.must(ok, '51 grow hurt H1')
        r = self.ems(0x5100, dx=H2, bx=4); self.T('51 H2 10->4        %s BX=%d' % (self.st(), r['bx']))
        ok = True
        for p in range(4):
            self.map(0, p, H2)
            if not self.checkwin(0, self.tag(H2, p)): ok = False
        self.T('  kept pages %d page 4 AH=%02X' % (ok, self.map(0, 4, H2))); self.must(ok, '51 shrink')
        r = self.ems(0x5100, dx=H2, bx=0); self.T('51 H2 ->0          %s BX=%d' % (self.st(), r['bx']))
        r = self.ems(0x4C00, dx=H2); self.T('  4C              %s BX=%d' % (self.st(), r['bx']))
        r = self.ems(0x5100, dx=H2, bx=3); self.T('51 H2 0->3         %s BX=%d' % (self.st(), r['bx']))
        for p in range(3):
            self.map(p, p, H2); self.fillwin(p, self.tag(H2, p))
        r = self.ems(0x5100, dx=H2, bx=9999); self.T('51 H2 ->9999       %s BX=%d' % (self.st(), r['bx']))
        self.ems(0x5100, dx=99, bx=1); self.T('51 handle 99       ' + self.st())
        ok = all((self.map(1, p, H1) == 0 and self.checkwin(1, self.tag(H1, p))) for p in range(64))
        self.T('  H1 intact %d' % ok); self.must(ok, '51 hurt H1')
        # a third handle allocated after the others, then H2 grown past it
        r = self.ems(0x4300, bx=2); H3 = r['dx']
        for p in range(2):
            self.map(p, p, H3); self.fillwin(p, self.tag(H3, p))
        r = self.ems(0x5100, dx=H2, bx=6); self.T('51 H2 3->6 past H3 %s BX=%d' % (self.st(), r['bx']))
        ok = all((self.map(0, p, H3) == 0 and self.checkwin(0, self.tag(H3, p))) for p in range(2))
        ok = ok and all((self.map(0, p, H2) == 0 and self.checkwin(0, self.tag(H2, p))) for p in range(3))
        self.T('  H2 and H3 intact %d' % ok); self.must(ok, '51 grow past another handle')
        self.ems(0x4500, dx=H3); self.T('45 free H3         ' + self.st())
        ok = all((self.map(0, p, H2) == 0 and self.checkwin(0, self.tag(H2, p))) for p in range(3))
        self.T('  H2 intact after %d' % ok); self.must(ok, '45 hurt H2')
        self.ems(0x5100, dx=H2, bx=3)

    # 57h -- the reference is read out with 44h, independent of 57h
    def mv(self, length, s, d):
        self.m.wr(DATA, MV, struct.pack('<IBHHHBHHH', length, *s, *d))

    def conv(self, seg, off):
        return (0, 0, off, seg)

    def exp(self, h, page, off):
        return (1, h, off, page)

    def reads(self, h, page, off, n):
        out = b''
        while len(out) < n:
            self.map(0, page, h)
            k = min(16384 - off, n - len(out))
            out += self.m.rd(FRAME, off, k)
            page += 1; off = 0
        return out

    def pattern(self, seed):
        return bytes(((k * 7 + seed + (k >> 8)) & 0xFF) for k in range(49152))

    def M(self, nm, sub):
        H1 = self.H1
        self.map(0, 1, H1); self.map(3, 2, H1)
        self.ems(0x5700 | sub, ds=DATA, si=MV)
        w = self.m.rd(self.winseg(0), 100, 2) == struct.pack('<H', self.tag(H1, 1)) and \
            self.m.rd(self.winseg(3), 100, 2) == struct.pack('<H', self.tag(H1, 2))
        self.T('%s%s win %d' % (nm, self.st(), w))

    def putbuf(self, seg, data):
        self.m.wr(seg, 0, data)

    def moves(self):
        H1, H2 = self.H1, self.H2
        A = self.pattern(1); self.putbuf(BUFA, A)
        self.mv(40001, self.conv(BUFA, 3), self.exp(H1, 4, 16383)); self.M('57/00 c->e 40001   ', 0)
        got = self.reads(H1, 4, 16383, 40001)
        ok = got == A[3:3 + 40001]
        fd = next((i for i in range(40001) if got[i] != A[3 + i]), 40001)
        self.T('57/00 c->e check   %d first bad %d' % (ok, fd)); self.must(ok, '57/00 c->e')
        self.putbuf(BUFB, bytes(49152))
        self.mv(40001, self.exp(H1, 4, 16383), self.conv(BUFB, 1)); self.M('57/00 e->c 40001   ', 0)
        B = self.m.rd(BUFB, 0, 49152)
        ok = B[1:40002] == A[3:40004]
        self.T('57/00 e->c check   %d' % ok); self.must(ok, '57/00 e->c')
        for i, n in enumerate((1, 2, 3, 16384, 16385, 32768)):
            A = self.pattern(i + 20); self.putbuf(BUFA, A)
            self.mv(n, self.conv(BUFA, 0), self.exp(H1, 12, 0)); self.M('57/00 c->e %-8d' % n, 0)
            got = self.reads(H1, 12, 0, n)
            ok = got == A[:n]
            fd = next((k for k in range(n) if got[k] != A[k]), n)
            self.T('  check %d first bad %d' % (ok, fd)); self.must(ok, '57/00 length %d' % n)
        before = self.reads(H1, 4, 100, 20000)
        self.mv(20000, self.exp(H1, 4, 100), self.exp(H2, 0, 5)); self.M('57/00 e->e h1->h2  ', 0)
        ok = self.reads(H2, 0, 5, 20000) == before
        self.T('  check %d' % ok); self.must(ok, '57/00 e->e')
        # overlap within one handle -- the expected result is what memmove gives
        for nm, so, do in (('57/00 overlap fwd  ', (20, 0), (20, 1000)), ('57/00 overlap back ', (24, 1000), (24, 0))):
            base = so[0]; region = bytearray(self.reads(H1, base, 0, 31000))
            s0 = so[1]; d0 = do[1]
            exp = bytearray(region); exp[d0:d0 + 30000] = region[s0:s0 + 30000]
            self.mv(30000, self.exp(H1, *so), self.exp(H1, *do)); self.M(nm, 0)
            ok = self.reads(H1, base, 0, 31000) == bytes(exp)
            self.T('  memmove result %d' % ok); self.must(ok, nm.strip())
        for nm, s0, d0 in (('57/00 c->c ovl fwd ', 0, 333), ('57/00 c->c ovl bk  ', 333, 0)):
            A = self.pattern(9); self.putbuf(BUFA, A)
            exp = bytearray(A); exp[d0:d0 + 10000] = A[s0:s0 + 10000]
            self.mv(10000, self.conv(BUFA, s0), self.conv(BUFA, d0)); self.M(nm, 0)
            ok = self.m.rd(BUFA, 0, 12000) == bytes(exp[:12000])
            self.T('  memmove result %d' % ok); self.must(ok, nm.strip())
        # odd sizes across a page, both directions, for the word-copy paths
        for n, so, do in ((1, 0, 0), (3, 16383, 1), (16383, 1, 16383), (33333, 15001, 7)):
            A = self.pattern(n & 0xFF); self.putbuf(BUFA, A)
            self.mv(n, self.conv(BUFA, so), self.exp(H1, 30, do)); self.M('57/00 c->e %d %d->%d ' % (n, so, do), 0)
            ok = self.reads(H1, 30, do, n) == A[so:so + n]
            self.putbuf(BUFB, bytes(49152))
            self.mv(n, self.exp(H1, 30, do), self.conv(BUFB, so)); self.M('57/00 e->c back ', 0)
            ok = ok and self.m.rd(BUFB, so, n) == A[so:so + n]
            self.T('  check %d' % ok); self.must(ok, '57/00 odd %d' % n)
        for nm, s, d in (('57/00 offset 16384 ', self.exp(H1, 4, 16384), self.conv(BUFB, 0)),):
            self.mv(16384, s, d); self.M(nm, 0)
        self.mv(16385 * 3, self.exp(H2, 1, 0), self.conv(BUFB, 0)); self.M('57/00 past handle  ', 0)
        self.mv(1048577, self.exp(H2, 1, 0), self.conv(BUFB, 0)); self.M('57/00 len > 1MB    ', 0)
        self.mv(100, self.exp(99, 0, 0), self.conv(BUFB, 0)); self.M('57/00 handle 99    ', 0)
        self.mv(100, self.exp(H1, 0, 0), (2, 0, 0, BUFB)); self.M('57/00 type 2       ', 0)
        self.mv(100, self.conv(0xFFFF, 0), self.conv(BUFB, 0)); self.M('57/00 wrap 1MB     ', 0)
        self.mv(0, self.conv(BUFA, 0), self.conv(BUFB, 0)); self.M('57/00 len 0        ', 0)
        # exchange
        A = self.pattern(77); self.putbuf(BUFA, A)
        E = self.reads(H1, 40, 16000, 20001)
        self.mv(20001, self.conv(BUFA, 1), self.exp(H1, 40, 16000)); self.M('57/01 c<->e 20001  ', 1)
        ok = self.m.rd(BUFA, 1, 20001) == E and self.reads(H1, 40, 16000, 20001) == A[1:20002]
        self.T('  check %d' % ok); self.must(ok, '57/01 c<->e')
        for n, so, do in ((1, 0, 0), (2, 1, 16383), (16385, 3, 2)):
            A = self.pattern(n & 0xFF ^ 0x33); self.putbuf(BUFA, A)
            E = self.reads(H1, 44, do, n)
            self.mv(n, self.conv(BUFA, so), self.exp(H1, 44, do)); self.M('57/01 c<->e %d      ' % n, 1)
            ok = self.m.rd(BUFA, so, n) == E and self.reads(H1, 44, do, n) == A[so:so + n]
            self.T('  check %d' % ok); self.must(ok, '57/01 %d' % n)
        self.mv(20000, self.exp(H1, 4, 0), self.exp(H1, 4, 100)); self.M('57/01 overlap      ', 1)
        a = self.reads(H1, 4, 0, 5000); b = self.reads(H2, 0, 1, 5000)
        self.mv(5000, self.exp(H1, 4, 0), self.exp(H2, 0, 1)); self.M('57/01 e<->e        ', 1)
        ok = self.reads(H1, 4, 0, 5000) == b and self.reads(H2, 0, 1, 5000) == a
        self.T('  check %d' % ok); self.must(ok, '57/01 e<->e')
        self.ems(0x5702, ds=DATA, si=MV); self.T('57/02              ' + self.st())

    def names(self):
        H1, H2 = self.H1, self.H2
        self.m.wr(DATA, NAMES, b'EMSTEST1EMSTEST2AAAAAAAA')
        self.ems(0x5301, dx=H1, ds=DATA, si=NAMES); self.T('53/01 name H1      ' + self.st())
        self.ems(0x5301, dx=H2, ds=DATA, si=NAMES); self.T('53/01 dup name     ' + self.st())
        self.ems(0x5301, dx=H2, ds=DATA, si=NAMES + 8); self.T('53/01 name H2      ' + self.st())
        self.ems(0x5300, dx=H1, es=BUFA, di=0); self.T('53/00 get H1       %s %s' % (self.st(), self.m.rd(BUFA, 0, 8)))
        r = self.ems(0x5401, ds=DATA, si=NAMES + 8); self.T('54/01 find N2      %s same=%d' % (self.st(), r['dx'] == H2))
        self.ems(0x5401, ds=DATA, si=NAMES + 16); self.T('54/01 find none    ' + self.st())
        r = self.ems(0x5402); self.T('54/02 total        %s BX=%d' % (self.st(), r['bx']))
        r = self.ems(0x5400, es=BUFA, di=0); self.T('54/00 dir          %s AL=%d' % (self.st(), (r['ax'] & 0xFF)))
        self.ems(0x5403); self.T('54/03              ' + self.st())
        r = self.ems(0x4D00, es=BUFA, di=0); self.T('4D all handles     %s BX=%d %s' % (self.st(), r['bx'], self.m.rd(BUFA, 0, 4 * r['bx']).hex()))
        r = self.ems(0x5200, dx=H1); self.T('52/00 attr H1      %s AL=%02X' % (self.st(), r['ax'] & 0xFF))
        self.ems(0x5201, dx=H1, bx=1); self.T('52/01 set attr     ' + self.st())
        r = self.ems(0x5202); self.T('52/02 capability   %s AL=%02X' % (self.st(), r['ax'] & 0xFF))
        r = self.ems(0x5800, es=BUFA, di=0); self.T('58/00 mappable     %s CX=%d %s' % (self.st(), r['cx'], self.m.rd(BUFA, 0, 16).hex()))
        r = self.ems(0x5801); self.T('58/01              %s CX=%d' % (self.st(), r['cx']))
        r = self.ems(0x5900, es=BUFA, di=0); self.T('59/00 hardware     %s %s' % (self.st(), self.m.rd(BUFA, 0, 10).hex()))
        r = self.ems(0x5901); self.T('59/01 raw pages    %s BX=%d DX=%d' % (self.st(), r['bx'], r['dx']))
        r = self.ems(0x5B02); self.T('5B/02 alt size     %s DX=%d' % (self.st(), r['dx']))
        r = self.ems(0x5B00); self.T('5B/00              %s BL=%02X ES:DI=%04X:%04X' % (self.st(), r['bx'] & 0xFF, r['es'], r['di']))
        r = self.ems(0x5B03); self.T('5B/03 alloc        %s BL=%02X' % (self.st(), r['bx'] & 0xFF))
        r = self.ems(0x5A00, bx=2); H4 = r['dx']; self.T('5A/00 alloc raw 2  ' + self.st())
        self.ems(0x4500, dx=H4)
        r = self.ems(0x5D02, bx=0x1111, cx=0x2222); self.T('5D/02 access key   ' + self.st())

    # 55h/56h: map and jump / map and call.  The target is a tiny routine
    # in low memory that records what window 0 shows and comes back.
    def jumpcall(self):
        H1 = self.H1
        m = self.m
        TGT = 0x0800      # linear, segment 0
        # target for 56h: read E000:0064 into [0:0900], RETF
        m.uc.mem_write(TGT, b'\x1e\x31\xc0\x8e\xd8\xb8\x00\xe0\x8e\xd8\xa1\x64\x00\x31\xdb\x8e\xdb\xa3\x00\x09\x1f\xcb')
        # 56h/00: new map page 50 -> phys 0, old map page 51 -> phys 0
        m.wr(DATA, 0x100, struct.pack('<HH', 50, 0))
        m.wr(DATA, 0x110, struct.pack('<HH', 51, 0))
        m.wr(DATA, 0x120, struct.pack('<HHBHHBHH', TGT, 0, 1, 0x100, DATA, 1, 0x110, DATA) + bytes(8))
        m.uc.mem_write(0x900, b'\0\0')
        self.map(0, 1, H1)
        r = self.ems(0x5600, dx=H1, ds=DATA, si=0x120)
        seen, = struct.unpack('<H', bytes(m.uc.mem_read(0x900, 2)))
        after = m.rd(FRAME, 100, 2) == struct.pack('<H', self.tag(H1, 51))
        self.T('56/00 map+call     %s saw %d after %d sp %04X' % (self.st(), seen == self.tag(H1, 50), after, r['sp']))
        self.must(seen == self.tag(H1, 50) and after, '56/00')
        r = self.ems(0x5602); self.T('56/02 stack        %s BX=%d' % (self.st(), r['bx']))
        # 56h/01 by segment
        m.wr(DATA, 0x100, struct.pack('<HH', 52, FRAME + 0x400))
        m.wr(DATA, 0x110, struct.pack('<HH', 53, FRAME + 0x400))
        # a second routine that reads E400h rather than patching the first:
        # the emulator caches translated code, so a patched routine can run stale
        TGT2 = 0x0840
        m.uc.mem_write(TGT2, b'\x1e\x31\xc0\x8e\xd8\xb8\x00\xe4\x8e\xd8\xa1\x64\x00\x31\xdb\x8e\xdb\xa3\x00\x09\x1f\xcb')
        m.wr(DATA, 0x120, struct.pack('<H', TGT2))
        r = self.ems(0x5601, dx=H1, ds=DATA, si=0x120)
        seen, = struct.unpack('<H', bytes(m.uc.mem_read(0x900, 2)))
        after = m.rd(FRAME + 0x400, 100, 2) == struct.pack('<H', self.tag(H1, 53))
        self.T('56/01 map+call seg %s saw %d after %d' % (self.st(), seen == self.tag(H1, 52), after))
        self.must(seen == self.tag(H1, 52) and after, '56/01')
        # 55h/00: map page 54 -> phys 2 and jump to a HLT; check where it lands
        m.uc.mem_write(0x0A00, b'\xf4')
        m.wr(DATA, 0x100, struct.pack('<HH', 54, 2))
        m.wr(DATA, 0x130, struct.pack('<HHBHH', 0x0A00, 0, 1, 0x100, DATA))
        uc = m.uc
        for k in REGS: uc.reg_write(REGS[k], 0)
        uc.reg_write(UC_X86_REG_AX, 0x5500); uc.reg_write(UC_X86_REG_DX, H1)
        uc.reg_write(UC_X86_REG_DS, DATA); uc.reg_write(UC_X86_REG_SI, 0x130)
        uc.reg_write(UC_X86_REG_SS, STACKSEG); uc.reg_write(UC_X86_REG_SP, 0xFFF0)
        m.run(0, STUB + 0x20, 0x0A00)
        ok = self.checkwin(2, self.tag(H1, 54)) and uc.reg_read(UC_X86_REG_SP) == 0xFFF0
        self.T('55/00 map+jump     AH=%02X %d' % (uc.reg_read(UC_X86_REG_AX) >> 8, ok))
        self.must(ok, '55/00')

    def free(self):
        H1, H2 = self.H1, self.H2
        self.ems(0x4500, dx=H1); self.T('45 free H1         ' + self.st())
        self.ems(0x4500, dx=H1); self.T('45 free H1 again   ' + self.st())
        self.ems(0x4500, dx=H2); self.T('45 free H2         ' + self.st())
        r = self.ems(0x4B00); self.T('4B handles         %s BX=%d' % (self.st(), r['bx']))
        r = self.ems(0x4200); self.T('42 free = total    %d' % (r['bx'] == r['dx']))


def load(path):
    d = open(path, 'rb').read()
    if d[:2] == b'MZ':
        last, pages, nrel, hdr = struct.unpack_from('<HHHH', d, 2)
        size = pages * 512 - (512 - last if last else 0)
        d = d[hdr * 16:size]
    return d


def transcript(path, **kw):
    m = Machine(load(path), **kw)
    lines = ['init: status %04X, resident %d bytes' % (m.init_status, m.resident)]
    lines += ['  | ' + s.replace('\r', '').replace('\n', ' ') for s in m.out]
    lines += Test(m).run()
    return lines


if __name__ == '__main__':
    import difflib
    ts = []
    for p in sys.argv[1:]:
        t = transcript(p)
        ts.append(t)
        print('=== %s ===' % p)
        print('\n'.join(t))
    if len(ts) >= 2:
        print('=== diff %s -> %s ===' % (sys.argv[1], sys.argv[2]))
        for l in difflib.unified_diff(ts[0], ts[1], lineterm='', n=0):
            print(l)
