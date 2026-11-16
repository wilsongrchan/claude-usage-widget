# Builds docs/images/desktop-menubar.png from desktop.png and menubar.png.
# usage (repo root): python3 tools/readme/desktop_menubar.py H G TOP   (display px; 2026-11-16: 219 30.5 27.5)
# H G (display px) -> writes docs/images/desktop-menubar.png at 2x, prints display width
import sys
from PIL import Image
H=float(sys.argv[1]); G=float(sys.argv[2]); TOP=float(sys.argv[3]) if len(sys.argv)>3 else 0; S=2
c=Image.open('docs/images/desktop.png').convert('RGBA'); d=Image.open('docs/images/menubar.png').convert('RGBA')
h=round(H*S); g=round(G*S)
c=c.resize((round(c.width*h/c.height),h),Image.LANCZOS); d=d.resize((round(d.width*h/d.height),h),Image.LANCZOS)
t=round(TOP*S); out=Image.new('RGBA',(c.width+g+d.width,h+t),(0,0,0,0)); out.alpha_composite(c,(0,t)); out.alpha_composite(d,(c.width+g,t))
out.save('docs/images/desktop-menubar.png',dpi=(144,144)); print(round(out.width/S,1))
