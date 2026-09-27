# Compare the LOAD IMAGES and entry points of two DOS .EXE files.
# The headers differ by linker (TLINK built the shipped PMEMM.EXE, JWlink
# builds ours), so the header bytes are not compared -- what DOS loads is.
# StevenC & Claude, 2026
import struct, sys
def load(p):
    d = open(p, 'rb').read()
    last, pages, nrel, hdr = struct.unpack_from('<HHHH', d, 2)
    ip, cs = struct.unpack_from('<HH', d, 0x14)
    size = pages * 512 - (512 - last if last else 0)
    return d[hdr * 16:size], (cs, ip), nrel
if sys.argv[1] == '--sys':
    # PMEMM.EXE has no relocations and its device header at image offset 0,
    # so the load image alone is a valid flat .SYS -- which DEVLOAD needs:
    # it does not take .EXE-format drivers.
    img, e, n = load(sys.argv[2])
    assert n == 0, 'relocations: cannot make a flat .SYS'
    open(sys.argv[3], 'wb').write(img)
    print('wrote %s (%d bytes)' % (sys.argv[3], len(img)))
    sys.exit(0)
a, ea, ra = load(sys.argv[1]); b, eb, rb = load(sys.argv[2])
if a == b and ea == eb and ra == rb:
    print('IDENTICAL load image to %s (%d bytes, entry %04X:%04X)' % (sys.argv[2], len(a), eb[0], eb[1]))
    sys.exit(0)
print('DIFFERS: sizes %d/%d entry %s/%s relocs %d/%d' % (len(a), len(b), ea, eb, ra, rb))
for i in range(min(len(a), len(b))):
    if a[i] != b[i]:
        print('first difference at image offset %04X' % i); break
sys.exit(1)
