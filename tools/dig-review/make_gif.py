#!/usr/bin/env python3
"""Assemble the centre/corner in-game capture sequences; no generated imagery."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
ROOT=Path(__file__).resolve().parents[2]
source=ROOT/'build/dig-gif'
out=source/'digging-two-impacts.gif'
font=ImageFont.truetype('/usr/share/fonts/google-noto/NotoSans-Regular.ttf',20)
frames=[]
for index in range(21):
    frame=Image.new('RGB',(1280,482),(24,26,29))
    draw=ImageDraw.Draw(frame)
    for side,(name,title) in enumerate([('centre','Centre strike'),('corner','Corner strike — chunk boundary')]):
        shot=Image.open(source/name/f'{index:02d}.png').convert('RGB')
        frame.paste(shot.crop((320,160,960,600)),(side*640,42))
        draw.text((side*640+18,9),title,font=font,fill='white')
    frames.append(frame)
# One palette across the animation avoids palette changes looking like flicker.
sheet=Image.new('RGB',(1280,482*len(frames)))
for i,f in enumerate(frames):sheet.paste(f,(0,i*482))
palette=sheet.quantize(colors=256,method=Image.Quantize.MEDIANCUT)
converted=[f.quantize(palette=palette,dither=Image.Dither.NONE) for f in frames]
durations=[850]+[150]*19+[1100]
converted[0].save(out,save_all=True,append_images=converted[1:],duration=durations,loop=0,optimize=False,disposal=2)
print(out)
print(f'{out.stat().st_size/1024/1024:.2f} MiB, {len(frames)} frames')
