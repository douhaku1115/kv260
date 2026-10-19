# -*- coding: utf-8 -*-
"""構成 (種類ごとの大きさと個数) の案を参照絵で見比べる（段7・段階2）。

tools/piece_table.py の KV_PIECES を案ごとに差し替えて、万華鏡に折り返した
1280x720 の絵と、中央を等倍で切り出した見比べ用の 1 枚を出す。
大きい 5 種 (棒・六角柱・丸い塊・三日月・気泡) は今のまま。

  使い方:  python tools/mix_variants.py     sim/mix_*.png と sim/mix_crop.png
"""
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kv_cell as K
from cell_res_test import fold

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CELL = 256

# 小ビーズを「見える最小の大きさ」に戻した値 (セル上で半径 1.0〜1.6 画素)。
# 0.0025〜0.00625 (半径 0.3〜0.8 画素) は 1 個の α の最大が平均 0.17 で、
# 260 個中 15% しか見えていなかった (tools/grain_audit.py で実測)
BEAD_S_R = (0.008, 0.0125)

# 粒を明るくする色。元 (kv_cell.COLORS) の青 #3a6bff・金 #f2c230・白 を同じ色相のまま淡くした。
# 細かくすると覆われる面積が減って暗い地が増える (mix1 で 49.8% → 43.3%) ので、粒の明るさで補う
BRIGHT_BEADS = ["#9db8ff", "#ffe08a", "#ffffff", "#ffffff"]

MIX1 = {"glass": 120, "stone": 100, "bead": 300, "bead_s": 600, "glitter": 900}
# 案: 名前 → {種類: 個数}, 小ビーズを戻すか, ビーズの色の差し替え。
# 小ビーズの大きさを変えない「今」も並べる
MIXES = [
    ("now",     "今",            {"glass": 300, "stone": 210, "bead": 260, "bead_s": 260, "glitter": 990},
     False, None),
    ("mix1",    "粒多め",        MIX1, True, None),
    ("mix1_br", "粒多め・明るい粒", MIX1, True, BRIGHT_BEADS),
]


def table_for(counts, fix_bead_s):
    out = []
    for key, name, mx, rmin, rmax, sink, cr, n in K.KV_PIECES:
        if key == "bead_s" and fix_bead_s:
            rmin, rmax = BEAD_S_R
        out.append((key, name, mx, rmin, rmax, sink, cr, counts.get(key, n)))
    return out


def main():
    orig = K.KV_PIECES
    orig_col = dict(K.COLORS)
    shots = []
    try:
        for tag, name, counts, fix, bead_col in MIXES:
            K.KV_PIECES = table_for(counts, fix)
            K.COLORS.update(orig_col)
            if bead_col:
                K.COLORS["bead"] = bead_col
                K.COLORS["bead_s"] = bead_col
            parts = K.make_parts(random.Random(3), False)
            back, front = K.render(parts, CELL)
            cell = np.clip(front[..., :3] + back[..., :3] * (1.0 - front[..., 3:4]), 0, 1)
            # 覆われ具合: 地 (油) から色が変わった画素の割合と、筒の中の平均の明るさ
            bg = K.R.oil_bg(CELL, 0.0)[..., :3]
            yy, xx = np.mgrid[0:CELL, 0:CELL]
            inside = ((xx + 0.5) / CELL * 2 - 1) ** 2 + ((yy + 0.5) / CELL * 2 - 1) ** 2 < 1.0
            cov = (np.abs(cell - bg).max(-1) > 0.05)[inside].mean()
            lum = cell.mean(-1)[inside].mean()
            print("        覆われた割合 %4.1f%%  平均の明るさ %.3f" % (100 * cov, lum))
            img = Image.fromarray((fold(cell) * 255 + 0.5).astype(np.uint8))
            out = os.path.join(ROOT, "sim", "mix_%s.png" % tag)
            img.save(out)
            print("  %-5s %-6s %4d 個 → %s" % (tag, name, len(parts), out))
            shots.append((tag, img))
    finally:
        K.KV_PIECES = orig
        K.COLORS.update(orig_col)

    # 中央付近を等倍で切り出して横に並べる (英字だけ。日本語の字形を持たないため)
    cw, ch = 420, 420
    w, h = shots[0][1].size
    box = (w // 2 - cw // 2 - 200, h // 2 - ch // 2, w // 2 + cw // 2 - 200, h // 2 + ch // 2)
    sheet = Image.new("RGB", (cw * len(shots), ch))
    for i, (tag, img) in enumerate(shots):
        x, y = i * cw, 0
        sheet.paste(img.crop(box), (x, y))
        ImageDraw.Draw(sheet).text((x + 6, y + 6), tag, fill=(255, 255, 255))
    out = os.path.join(ROOT, "sim", "mix_crop.png")
    sheet.save(out)
    print("  見比べ → %s" % out)


if __name__ == "__main__":
    main()
