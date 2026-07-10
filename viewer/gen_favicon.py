#!/usr/bin/env python3
"""Generate the Teams Record Viewer multi-size favicon.ico as base64."""
import base64
import io

from PIL import Image, ImageDraw


PURPLE = '#5b5fc7'
WHITE = '#ffffff'
SIZES = (16, 32, 48)
BASE = 32
SUPERSAMPLE = 4


def scaled(value, scale):
    return value * scale


def draw_icon(size):
    canvas_size = size * SUPERSAMPLE
    scale = canvas_size / BASE
    img = Image.new('RGBA', (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    draw.rounded_rectangle(
        (0, 0, canvas_size, canvas_size),
        radius=scaled(7, scale),
        fill=PURPLE,
    )
    draw.rounded_rectangle(
        (
            scaled(6, scale),
            scaled(8, scale),
            scaled(26, scale),
            scaled(22, scale),
        ),
        radius=scaled(3.5, scale),
        fill=WHITE,
    )
    draw.polygon(
        [
            (scaled(11, scale), scaled(22, scale)),
            (scaled(11, scale), scaled(27, scale)),
            (scaled(16, scale), scaled(22, scale)),
        ],
        fill=WHITE,
    )
    for cx in (12, 16, 20):
        r = scaled(1.7, scale)
        x = scaled(cx, scale)
        y = scaled(15, scale)
        draw.ellipse((x - r, y - r, x + r, y + r), fill=PURPLE)

    return img.resize((size, size), Image.Resampling.LANCZOS)


def main():
    icons = [draw_icon(size) for size in SIZES]
    out = io.BytesIO()
    icons[-1].save(out, format='ICO', sizes=[(size, size) for size in SIZES], append_images=icons[:-1])
    print(base64.b64encode(out.getvalue()).decode('ascii'))


if __name__ == '__main__':
    main()
