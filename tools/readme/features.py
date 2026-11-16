# Builds docs/images/features-light.png and features-dark.png from the cropped widget shots
# (large.png, medium.png, small.png, small-mono.png, all 2x). Run from the repo root:
#   python3 tools/readme/features.py
import os, sys; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cutout import cut
from PIL import Image, ImageDraw, ImageFont, ImageFilter
large=cut('docs/images/large.png')[0]; med=cut('docs/images/medium.png')[0]; sm=cut('docs/images/small.png')[0]; mono=cut('docs/images/small-mono.png')[0]   # already 2x
def font(wt,sz):
    f=ImageFont.truetype('/System/Library/Fonts/SFNS.ttf',sz)
    try: f.set_variation_by_name(wt)
    except Exception: pass
    return f
T=font('Semibold',46); D=font('Regular',36); LH=44
W=1320; SCALE=1.0; GAPV=56
themes={'light':((31,35,40),(89,99,110),(140,149,159)),'dark':((230,237,243),(145,152,161),(110,118,129))}

def panel(tiles, notes, GX, GY, H, theme):
    tc,dc,lc=theme
    c=Image.new('RGBA',(W,H),(0,0,0,0)); sh=Image.new('RGBA',(W,H),(0,0,0,0))
    for im,(x,y) in tiles:
        s=Image.new('RGBA',im.size,(0,0,0,0)); s.putalpha(im.getchannel('A').point(lambda v:int(v*.22))); sh.alpha_composite(s,(GX+x,GY+y+8))
    c.alpha_composite(sh.filter(ImageFilter.GaussianBlur(14)))
    for im,(x,y) in tiles: c.alpha_composite(im,(GX+x,GY+y))
    d=ImageDraw.Draw(c)
    for title,desc,al,path in notes:
        path=[(GX+x,GY+y) for x,y in path]
        d.line(path,fill=lc+(255,),width=4,joint='curve')
        ex,ey=path[-1]
        if al=='r': tx,anc=ex-16,'rm'
        elif al=='l': tx,anc=ex+16,'lm'
        else: tx,anc=ex,'lm'; ey+=34          # 'b': label below the line end
        d.text((tx,ey),title,font=T,fill=tc,anchor=anc)
        for i,l in enumerate(desc): d.text((tx,ey+46+i*LH),l,font=D,fill=dc,anchor=anc)
        px,py=path[0]
        d.ellipse((px-12,py-12,px+12,py+12),fill=(255,255,255,255)); d.ellipse((px-8,py-8,px+8,py+8),fill=(217,119,87,255))
    return c

# All labels on the right; widgets flush left. Lines run through the gaps between tiles.
RX=728   # where every label line ends (grid coords)
A_tiles=[(med,(0,0)),(sm,(0,360)),(mono,(360,360))]
A_notes=[
 ('Medium',['Both rings side by side'],'l',[(684,164),(RX,164)]),
 ('Small',['Weekly as the outer ring'],'l',[(324,450),(344,450),(344,344),(RX,344)]),
 ('Monochrome',['Fades like native widgets','while you\'re in an app'],'l',[(684,500),(RX,500)]),
 ('Run-out forecast',['When you\'ll hit the limit'],'l',[(398,656),(398,716),(RX,716)]),
]
B_tiles=[(large,(0,0))]
B_notes=[   # large widget, cut-out coordinates (688x688)
 ('Session ring',['5 slices, one per hour'],'l',[(275,196),(275,40),(RX,40)]),
 ('Pace marker',['Even-pace point'],'l',[(298,374),(346,374),(346,140),(RX,140)]),
 ('Weekly ring',['7 slices, one per day'],'l',[(625,240),(RX,240)]),
 ('Pace note',['On pace, ahead, or to spare'],'l',[(612,486),(650,486),(650,360),(RX,360)]),
 ('Model limit bar',['e.g. Fable weekly'],'l',[(382,573),(382,520),(RX,520)]),
 ('Saved resets',['Reminders before expiry'],'l',[(570,632),(RX,632)]),
]
for name,th in themes.items():
    A=panel(A_tiles,A_notes,GX=20,GY=20,H=20+688+130,theme=th)
    B=panel(B_tiles,B_notes,GX=20,GY=10,H=10+688+40,theme=th)
    out=Image.new('RGBA',(W,A.height+GAPV+B.height),(0,0,0,0)); out.alpha_composite(A,(0,0)); out.alpha_composite(B,(0,A.height+GAPV))
    bb=out.getchannel('A').getbbox(); out=out.crop((0,max(0,bb[1]-6),W,bb[3]+4))   # no empty margin top or bottom
    TOPPAD=162   # nudges the column down so C/D (as tall as B) end level with B's bottom edge
    pad=Image.new('RGBA',(W,out.height+TOPPAD),(0,0,0,0)); pad.alpha_composite(out,(0,TOPPAD)); out=pad
    out=out.resize((round(W*SCALE),round(out.height*SCALE)),Image.LANCZOS)
    out.save(f'docs/images/features-{name}.png',dpi=(144,144))
    print(out.size)
