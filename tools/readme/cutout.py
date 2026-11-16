from PIL import Image, ImageDraw
import numpy as np
def rim_box(im):
    a=np.asarray(im.convert('L')).astype(int); H,W=a.shape
    r=a[H//2].astype(float); c=a[:,W//2].astype(float)
    def first(v): d=np.diff(v[:60]); return int(np.argmax(d))+1          # biggest jump into the rim
    def last(v): d=np.diff(v[::-1][:60]); return len(v)-1-(int(np.argmax(d))+1)
    return first(r), first(c), last(r), last(c)
def cut(path, scale=1, inset=1.5, radius=52):
    im=Image.open(path).convert('RGBA')
    if scale!=1: im=im.resize((im.width*scale, im.height*scale), Image.LANCZOS)
    x0,y0,x1,y1=rim_box(im)
    w=im.crop((x0,y0,x1+1,y1+1))
    S=8; mk=Image.new('L',(w.width*S,w.height*S),0)
    i=inset*S
    ImageDraw.Draw(mk).rounded_rectangle((i,i,w.width*S-1-i,w.height*S-1-i),radius=(radius-inset)*S,fill=255)
    w.putalpha(mk.resize(w.size,Image.LANCZOS))
    return w,(x0,y0,x1,y1)
