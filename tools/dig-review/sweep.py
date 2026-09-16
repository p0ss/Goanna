#!/usr/bin/env python3
"""Render a moving-impact diagnostic from native occupancy, not a second model."""
import json
import subprocess
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/dig-gif'
OUT.mkdir(parents=True, exist_ok=True)
font = ImageFont.truetype('/usr/share/fonts/google-noto/NotoSans-Regular.ttf', 17)
cases = [json.loads(s) for s in subprocess.check_output(
    [str(ROOT/'build/goanna_radial_form_test'), '--dump-impacts'], text=True).splitlines()]
cases = [c for c in cases if c['step'] == 3 and abs(c['hit'][2]-.13) < .0001]
frames = []
for case in cases:
    frame = Image.new('RGB', (760,410), '#20252d')
    draw = ImageDraw.Draw(frame)
    grid = case['grid']
    def solid(x,y,z):
        return 0 <= x < 16 and 0 <= y < 16 and 0 <= z < 16 and grid[z*256+y*16+x] == '1'
    def project(x,y,z):
        return (505+(x-z)*11, 222+(x+z)*5-y*9)
    faces = []
    for z in range(16):
        for x in range(16):
            height = max((y+1 for y in range(16) if solid(x,y,z)), default=0)
            shade = int(45+190*height/16)
            draw.rectangle((26+x*13,104+z*13,38+x*13,116+z*13), fill=(shade,shade,shade))
            for y in range(16):
                if not solid(x,y,z): continue
                for axis, delta, offsets, color in [
                    (0,(1,0,0),[(1,0,0),(1,1,0),(1,1,1),(1,0,1)],'#72808c'),
                    (1,(0,1,0),[(0,1,0),(1,1,0),(1,1,1),(0,1,1)],'#cad5db'),
                    (2,(0,0,1),[(0,0,1),(1,0,1),(1,1,1),(0,1,1)],'#95a3ac')]:
                    if not solid(x+delta[0],y+delta[1],z+delta[2]):
                        vertices = [(x+a,y+b,z+c) for a,b,c in offsets]
                        faces.append((sum(x+y+z for x,y,z in vertices), vertices, color))
    for _, vertices, color in sorted(faces):
        draw.polygon([project(*v) for v in vertices], fill=color, outline='#53616b')
    hx, _, hz = case['hit']
    mx, mz = 26+(hx+.5)*208, 104+(hz+.5)*208
    draw.ellipse((mx-4,mz-4,mx+4,mz+4),fill='#fc7363')
    draw.text((20,14),'Moving impact • same depth • native 16³ occupancy',font=font,fill='white')
    draw.text((26,70),'Top height / impact point',font=font,fill='white')
    draw.text((26,344),f'Hit x={hx:+.2f}, z={hz:.2f}',font=font,fill='white')
    draw.text((26,375),'Fresh block at every position; stepped changes come from subcube sampling.',font=font,fill='#c2c8cf')
    frames.append(frame)
frames[0].save(OUT/'impact-sweep.gif',save_all=True,append_images=frames[1:]+frames[-2:0:-1],duration=160,loop=0)
sheet = Image.new('RGB',(760*3,410),'#20252d')
for i,index in enumerate([4,9,14]): sheet.paste(frames[index],(760*i,0))
sheet.save(OUT/'impact-sweep.png')
print(OUT/'impact-sweep.gif')
