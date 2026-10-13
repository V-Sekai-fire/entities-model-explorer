
import sys,zlib,struct,glob
def dark(fn):
    d=open(fn,'rb').read(); i=8; idat=b''; w=h=0
    while i<len(d):
        n=struct.unpack('>I',d[i:i+4])[0]; t=d[i+4:i+8]; c=d[i+8:i+8+n]
        if t==b'IHDR': w,h,bd,ct=struct.unpack('>IIBB',c[:10])
        if t==b'IDAT': idat+=c
        i+=12+n
    raw=zlib.decompress(idat); bpp=4 if ct==6 else 3; st=w*bpp; prev=bytearray(st); rows=[]; o=0
    for y in range(h):
        f=raw[o]; o+=1; cur=bytearray(raw[o:o+st]); o+=st
        for x in range(st):
            a=cur[x-bpp] if x>=bpp else 0; b=prev[x]; cc=prev[x-bpp] if x>=bpp else 0
            if f==1: cur[x]=(cur[x]+a)&255
            elif f==2: cur[x]=(cur[x]+b)&255
            elif f==3: cur[x]=(cur[x]+(a+b)//2)&255
            elif f==4:
                pp=a+b-cc; pa,pb,pc=abs(pp-a),abs(pp-b),abs(pp-cc)
                cur[x]=(cur[x]+(a if pa<=pb and pa<=pc else b if pb<=pc else cc))&255
        rows.append(cur); prev=cur
    tot=dk=0
    for y in range(60,h-60,6):
        r=rows[y]
        for x in range(0,w,6):
            p=r[x*bpp:x*bpp+3]; tot+=1
            if max(p)<48: dk+=1
    return dk/tot
for fn in sorted(glob.glob(sys.argv[1]+'*.png'), key=lambda f:int(f.rsplit('-',1)[1][:-4])):
    print(fn.rsplit('/',1)[1], round(dark(fn),3))
