"""ans2png.py -- render CAMSNAP's .ANS half-block art as a PNG.
CH375Camera, StevenC.  Public domain (the Unlicense).

    python ans2png.py SNAP.ANS SNAP-ANSI.PNG [pixels-per-half-cell]

Reads the escape codes in the file -- SGR colours, bold for the bright
set, and the upper, lower and full half-block characters (CP437 223, 220,
219) -- and draws each character cell as its two coloured halves.  It is
how the README shows ANSI art that GitHub cannot display.
"""
import re, sys
from PIL import Image
CGA=[(0,0,0),(170,0,0),(0,170,0),(170,85,0),(0,0,170),(170,0,170),(0,170,170),(170,170,170)]
BRIGHT=[(85,85,85),(255,85,85),(85,255,85),(255,255,85),(85,85,255),(255,85,255),(85,255,255),(255,255,255)]
data=open(sys.argv[1],'rb').read().decode('cp437')
rows=[]; fg=7; bg=0; bold=False
for line in data.split('\r\n'):
    cells=[]
    for m in re.finditer(r'\x1b\[([0-9;]*)m|(.)', line, re.S):
        if m.group(1) is not None:
            for p in (m.group(1) or '0').split(';'):
                p=int(p or 0)
                if p==0: bold=False; fg=7; bg=0
                elif p==1: bold=True
                elif 30<=p<=37: fg=p-30
                elif 40<=p<=47: bg=p-40
        elif m.group(2):
            f=(BRIGHT if bold else CGA)[fg]; b=CGA[bg]; ch=m.group(2)
            top,bot = {'\u2580':(f,b),'\u2584':(b,f),'\u2588':(f,f)}.get(ch,(b,b))
            cells.append((top,bot))
    if cells: rows.append(cells)
W=max(len(r) for r in rows); S=int(sys.argv[3]) if len(sys.argv)>3 else 8
im=Image.new('RGB',(W*S,len(rows)*2*S))
for y,r in enumerate(rows):
    for x,(t,b) in enumerate(r):
        im.paste(t,(x*S,y*2*S,(x+1)*S,y*2*S+S)); im.paste(b,(x*S,y*2*S+S,(x+1)*S,(y+1)*2*S))
im.save(sys.argv[2]); print(W,'x',len(rows),'cells')
