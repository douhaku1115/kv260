# -*- coding: utf-8 -*-
"""発色の候補を参照絵で見比べる（段7 の下調べ）。

今の重ね方は α 合成だけ:  下 = 上の色*α + 下*(1-α)
ここに種類ごとの重ね方を足して、万華鏡に折り返した絵を出す。

  alpha   今のまま
  add     光を足す       下 = 上の色*α + 下          (重なると明るくなる。上は 1 で切る)
  screen  柔らかく足す   下 = 上の色*α + 下*(1-上の色*α)   (白へは飛ばない)

候補 (VARIANTS) ごとに、どの種類をどの重ね方にするか、ガラスの透け具合と
明るさをどうするかを決めて描く。PL では
  ・重ね方   … 表の 23 語目の空きビットで種類ごとに選ぶ (RTL の変更)
  ・透け・明るさ … ガラスのプログラム (pprog) の係数
にあたる。

  使い方:  python tools/look_variants.py      sim/look_*.png と sim/look_all.png
"""
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ref_cell as R
import kv_cell as K
from cell_res_test import fold

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CELL = 256                       # PL のセルと同じ解像度で直接描く

# 候補。mode: 種類 → 重ね方。glass_a: ガラスの α に掛ける係数。glass_k: ガラスの色に掛ける係数
VARIANTS = [
    ("A_now",    "今のまま (α 合成)",               {},                                   1.0, 1.0),
    ("B_add",    "ガラス・ラメを加算",              {"glass": "add", "glitter": "add"},   1.0, 1.0),
    ("C_screen", "ガラス・ラメをスクリーン",        {"glass": "screen", "glitter": "screen"}, 1.0, 1.0),
    ("D_glow",   "ガラスを薄く透かして加算・明るく", {"glass": "add", "glitter": "add"},   0.6, 1.4),
    ("E_all",    "ビーズ・石もスクリーン",          {"glass": "screen", "glitter": "screen",
                                                      "bead": "screen", "bead_s": "screen",
                                                      "stone": "screen"},                 1.0, 1.0),
]


def draw_parts_v(buf, parts, n, t, mode, glass_a, glass_k, u_size=1.0):
    """ref_cell.draw_parts と同じ。重ね方だけ種類ごとに変える"""
    for p in parts:
        typ = int(p["type"])
        r = p["r"] * u_size * (0.85 + 0.3 * p["z"])
        pad = 2.6 if typ == R.GLITTER else 1.2
        half = r * pad
        x0 = int(np.floor((p["x"] - half + 1.0) * 0.5 * n))
        x1 = int(np.ceil((p["x"] + half + 1.0) * 0.5 * n))
        y0 = int(np.floor((p["y"] - half + 1.0) * 0.5 * n))
        y1 = int(np.ceil((p["y"] + half + 1.0) * 0.5 * n))
        x0, x1 = max(x0, 0), min(x1, n)
        y0, y1 = max(y0, 0), min(y1, n)
        if x0 >= x1 or y0 >= y1:
            continue
        ix, iy = np.meshgrid(np.arange(x0, x1), np.arange(y0, y1))
        sx = (ix + 0.5) / n * 2.0 - 1.0
        sy = (iy + 0.5) / n * 2.0 - 1.0
        vqx = (sx - p["x"]) / r
        vqy = (sy - p["y"]) / r
        ca, sa = np.cos(p["rot"]), np.sin(p["rot"])
        qx = ca * vqx - sa * vqy
        qy = sa * vqx + ca * vqy

        rgb, a = K.shade_piece(p, qx, qy, vqx, vqy, t)
        if p["key"] == "glass":
            a = a * glass_a
            rgb = rgb * glass_k
        src = rgb * a[..., None] if typ != R.GLITTER else rgb
        src = np.clip(src, 0.0, 1.0)
        sub = buf[y0:y1, x0:x1]
        m = mode.get(p["key"], "alpha")
        if m == "add":
            sub[..., :3] = np.minimum(sub[..., :3] + src, 1.0)
        elif m == "screen":
            sub[..., :3] = src + sub[..., :3] * (1.0 - src)
        else:
            sub[..., :3] = src + sub[..., :3] * (1.0 - a)[..., None]
        sub[..., 3:4] = a[..., None] + sub[..., 3:4] * (1.0 - a)[..., None]


def render_v(parts, n, mode, glass_a, glass_k):
    s = sorted(parts, key=lambda p: p["z"])
    back = R.oil_bg(n, 0.0)
    draw_parts_v(back, [p for p in s if p["z"] < 0.5], n, 0.0, mode, glass_a, glass_k)
    front = np.zeros((n, n, 4))
    draw_parts_v(front, [p for p in s if p["z"] >= 0.5], n, 0.0, mode, glass_a, glass_k)
    return np.clip(front[..., :3] + back[..., :3] * (1.0 - front[..., 3:4]), 0, 1)


def main():
    rng = random.Random(3)
    parts = K.make_parts(rng, False)
    print("ピース %d 個、セル %d" % (len(parts), CELL))
    tiles = []
    for tag, name, mode, ga, gk in VARIANTS:
        cell = render_v(parts, CELL, mode, ga, gk)
        img = fold(cell)
        out = os.path.join(ROOT, "sim", "look_%s.png" % tag)
        im = Image.fromarray((img * 255 + 0.5).astype(np.uint8))
        im.save(out)
        print("  %-9s %s → %s" % (tag, name, out))
        tiles.append((tag, im))

    # 見比べ用に縮めて並べる (英字だけ。日本語の字形を持たないため)
    w, h = tiles[0][1].size
    sw, sh = w // 2, h // 2
    sheet = Image.new("RGB", (sw * 3, sh * 2), (0, 0, 0))
    for i, (tag, im) in enumerate(tiles):
        x, y = (i % 3) * sw, (i // 3) * sh
        sheet.paste(im.resize((sw, sh), Image.LANCZOS), (x, y))
        ImageDraw.Draw(sheet).text((x + 8, y + 8), tag, fill=(255, 255, 255))
    out = os.path.join(ROOT, "sim", "look_all.png")
    sheet.save(out)
    print("  一覧 → %s" % out)


if __name__ == "__main__":
    main()
