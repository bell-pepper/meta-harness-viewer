"""Build public, illustrative PDF pages, their HUD rasters, icons and install QR.

Build-time dependencies only: Pillow, PyMuPDF, qrcode. No document is uploaded.
Run from any directory; generated assets are committed for static hosting.
"""
from pathlib import Path
import io
import sys
import fitz
from PIL import Image, ImageDraw, ImageOps
import qrcode

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets' / 'demo'
OUT.mkdir(parents=True, exist_ok=True)
LAUNCH_URL = 'https://bell-pepper.github.io/meta-harness-viewer/'
from urllib.parse import urlencode
INSTALL_URL = 'fb-viewapp://web_app_deep_link?' + urlencode({'appName': 'Harness HUD', 'appUrl': LAUNCH_URL})

pdf = fitz.open()
for number in range(2):
    p = pdf.new_page(width=600, height=800)
    def text(x, y, label, size=24):
        p.insert_text((x, y), label, fontsize=size, fontname='helv')
    text(32, 48, 'HARNESS HUD / TEST DATASHEET', 26)
    text(32, 82, f'EXAMPLE ONLY - REV A - PAGE {number + 1} OF 2', 18)
    p.draw_line((32, 98), (568, 98), width=2)
    if number == 0:
        text(32, 144, 'J1 connector pinout', 30)
        text(32, 184, 'Illustrative signals. Not an approved drawing.', 18)
        for y, row in zip([242, 300, 358, 416, 474], [
            ('PIN', 'SIGNAL', 'WIRE'), ('1', '+12 V', 'RED'),
            ('2', 'GROUND', 'BLACK'), ('3', 'CAN H', 'WHITE'), ('4', 'CAN L', 'BLUE')]):
            for x, value in zip([40, 150, 390], row):text(x,y,value)
            p.draw_line((32, y+16), (568, y+16), width=1)
        text(32, 548, 'Orientation: mating face', 24)
        text(32, 590, 'Confirm cavity numbering on the approved', 22)
        text(32, 622, 'connector drawing before actual wiring.', 22)
        text(32, 682, 'Try: Zoom 3x, then Move with the arrows.', 22)
    else:
        text(32, 144, 'Inspection reference', 30)
        lines = ['1. Verify drawing and revision.', '2. Check wire IDs and cavities.',
                 '3. Inspect crimps and strain relief.', '4. Test continuity and isolation.',
                 '5. Record results using approved criteria.']
        for i, line in enumerate(lines):text(32, 212 + i*60, line, 23)
        text(32, 570, 'Zoom movement check', 26)
        text(32, 612, 'Use Move mode to reach each page edge.', 22)
        text(32, 648, 'Enter or Back exits Move mode.', 22)
    text(32, 122, 'TOP LEFT', 12)
    text(488, 122, 'TOP RIGHT', 12)
    text(32, 768, 'BOTTOM LEFT', 14)
    text(450, 768, 'BOTTOM RIGHT', 14)
    # Invert only the raster: white ink on black suits the additive display.
    pix = p.get_pixmap(matrix=fitz.Matrix(2, 2), alpha=False)
    raster = Image.open(io.BytesIO(pix.tobytes('png'))).convert('L')
    ImageOps.invert(raster).save(OUT / f'page-{number+1}.png', optimize=True)
pdf.save(OUT / 'harness-test.pdf', garbage=4, deflate=True)
pdf.close()

# A simple connector glyph; pure white with transparent surrounding pixels.
for size in [192, 512]:
    im = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(im)
    def box(values): return tuple(round(v*size/512) for v in values)
    width = max(4, round(24*size/512))
    draw.rounded_rectangle(box((92, 132, 420, 360)), radius=round(30*size/512), outline='white', width=width)
    for x in [164, 256, 348]:
        draw.line(box((x, 72, x, 132)), fill='white', width=width)
        draw.line(box((x, 360, x, 432)), fill='white', width=width)
        draw.ellipse(box((x-16, 230, x+16, 262)), fill='white')
    im.save(ROOT / 'icons' / f'icon-{size}.png', optimize=True)
qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=8, border=4)
qr.add_data(INSTALL_URL)
qr.make(fit=True)
qr.make_image(fill_color='black', back_color='white').save(ROOT / 'icons' / 'install-qr.png')
print('Built demo PDF, page images, launcher icons and install QR.')
print(INSTALL_URL)
