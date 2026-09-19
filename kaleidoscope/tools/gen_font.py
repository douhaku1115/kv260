# -*- coding: utf-8 -*-
"""画面に文字を出すための 8x16 フォントを作る。

ASCII 0x20〜0x7E の 95 文字を、Windows の等幅フォントから 8x16 に焼き直して
rtl/font_rom.hex に出す。1 行 = 1 バイト (MSB が左端)。
  アドレス = (ch - 0x20) * 16 + row

Tetris の font_rom.v は数字と一部の英字しか持っていないので作り直した。
字形を手で打ち込まず、システムのフォントから起こすことで間違いを避ける。

  使い方:  python tools/gen_font.py [フォント名] [サイズ]
"""
import os
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 8, 16
FIRST, LAST = 0x20, 0x7E

CANDIDATES = [
    ("C:/Windows/Fonts/consola.ttf", 14),
    ("C:/Windows/Fonts/cour.ttf", 15),
    ("C:/Windows/Fonts/lucon.ttf", 14),
]


def pick_font():
    if len(sys.argv) > 2:
        return sys.argv[1], int(sys.argv[2])
    for path, size in CANDIDATES:
        if os.path.exists(path):
            return path, size
    raise SystemExit("等幅フォントが見つからない")


def main():
    path, size = pick_font()
    print("使うフォント: %s  サイズ %d" % (path, size))
    font = ImageFont.truetype(path, size)

    rows = []
    preview = Image.new("L", (W * 16, H * 6), 0)

    for i, code in enumerate(range(FIRST, LAST + 1)):
        img = Image.new("L", (W, H), 0)
        d = ImageDraw.Draw(img)
        ch = chr(code)
        # 文字の外接枠を見て、8x16 の中に収まるよう左上に寄せる
        bb = d.textbbox((0, 0), ch, font=font)
        d.text((-bb[0], -bb[1] + 1), ch, font=font, fill=255)
        a = np.asarray(img)
        # 2値化。アンチエイリアスは切り捨てる (1bit フォントなので)
        bits = (a > 96).astype(np.uint8)
        for r in range(H):
            rows.append(int("".join(str(b) for b in bits[r]), 2))
        preview.paste(Image.fromarray(bits * 255), ((i % 16) * W, (i // 16) * H))

    with open("rtl/font_rom.hex", "w") as f:
        f.write("\n".join("%02x" % v for v in rows) + "\n")
    print("wrote rtl/font_rom.hex  (%d 文字 x %d 行 = %d バイト)"
          % (LAST - FIRST + 1, H, len(rows)))

    preview.resize((preview.width * 3, preview.height * 3), Image.NEAREST).save("sim/font_preview.png")
    print("wrote sim/font_preview.png  (目で確かめる用)")


if __name__ == "__main__":
    main()
