"""Generate the opaque 1024px Orbital app icon. Requires Pillow."""
from pathlib import Path
from math import sqrt
from PIL import Image, ImageDraw, ImageFilter

size, scale = 1024, 2
canvas = Image.new('RGB', (size, size))
pixels = canvas.load()
for y in range(size):
    for x in range(size):
        glow = max(0, 1 - sqrt(((x-540)/760)**2 + ((y-370)/800)**2))
        pixels[x, y] = (int(7+8*glow), int(14+24*glow), int(25+30*glow))
canvas = canvas.resize((size*scale, size*scale))
lines = Image.new('RGBA', canvas.size)
draw = ImageDraw.Draw(lines)
def box(values): return tuple(round(v*scale) for v in values)
for i in range(64, 1024, 64):
    draw.line(box((i,0,i,1024)), fill=(100,185,195,13), width=1)
    draw.line(box((0,i,1024,i)), fill=(100,185,195,13), width=1)
draw.arc(box((182,182,842,842)), 8, 306, fill=(116,230,219,210), width=4*scale)
draw.arc(box((148,148,876,876)), 112, 247, fill=(145,164,190,65), width=2*scale)
draw.arc(box((228,228,796,796)), 235, 346, fill=(180,161,245,100), width=2*scale)
draw.ellipse(box((755,230,783,258)), fill=(116,230,219,255))
draw.ellipse(box((182,586,194,598)), fill=(180,161,245,255))
draw.rounded_rectangle(box((365,330,654,694)), radius=30*scale, fill=(24,61,70,255), outline=(116,230,219,255), width=5*scale)
draw.line(box((414,332,414,648)), fill=(116,230,219,220), width=4*scale)
draw.rounded_rectangle(box((413,643,650,691)), radius=17*scale, fill=(11,25,39,255), outline=(116,230,219,220), width=4*scale)
for y in (660,673):
    draw.line(box((442,y,625,y)), fill=(165,199,215,100), width=2*scale)
draw.line(box((471,415,589,415)), fill=(234,243,252,230), width=5*scale)
draw.line(box((471,443,558,443)), fill=(145,166,188,180), width=4*scale)
draw.polygon([box((530,515)),box((556,559)),box((530,583)),box((504,559))], fill=(116,230,219,255))
canvas = Image.alpha_composite(canvas.convert('RGBA'), lines)
canvas = canvas.resize((size,size), Image.Resampling.LANCZOS).convert('RGB')
output = Path(__file__).resolve().parents[1] / 'yudu/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png'
canvas.save(output)
print(f'Wrote {output.name}: {canvas.width} × {canvas.height}, opaque RGB')
