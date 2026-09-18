"""rawcal.py -- read a CAMCAL recording.  CH375Camera, StevenC.  Public domain.

    python rawcal.py CAL.DAT

CAMCAL records every IN token as one length byte (FFh = failed) and that
many bytes.  This splits the recording into frames -- a run of 8 or more
empty packets is vertical blanking -- and prints each frame's size, packet
sizes, and where the 00 FF markers fall.  It is how the frame layout of
every mode was measured: whole 176x144 frames were 13834 bytes, 13824 of
picture and ten of header.
"""
import sys
from collections import Counter
def load(fn):
    d=open(fn,'rb').read(); p=0; out=[]
    while p<len(d):
        l=d[p]; p+=1
        if l==0xFF: out.append(None); continue
        out.append(d[p:p+l]); p+=l
    return out
def frames(pk, run=8):
    fr=[]; cur=[]; z=0
    for b in pk:
        if b is None: continue
        if len(b)==0:
            z+=1
            if z>=run and cur: fr.append(cur); cur=[]
            continue
        z=0; cur.append(b)
    if cur: fr.append(cur)
    return fr
if __name__=='__main__':
    pk=load(sys.argv[1])
    print('tokens',len(pk),Counter((len(b) if b is not None else -1) for b in pk).most_common(10))
    for f in frames(pk)[:10]:
        tot=sum(len(b) for b in f)
        ff=[i for i,b in enumerate(f) if len(b)>=2 and b[0]==0 and b[1]==0xff]
        firstff = ff[0] if ff else None
        data=sum(len(b) for b in f[:firstff]) if firstff is not None else tot
        print('frame: packets',len(f),'bytes',tot,'00FF pkts at',ff[:5],'bytes before first 00FF',data,'| first',f[0][:10].hex(' '))
