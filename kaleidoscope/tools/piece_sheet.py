# -*- coding: utf-8 -*-
"""9種を並べて1枚にする。形と陰影を1個ずつ目で確かめるためのもの。

各行が1種類。左から右へ大きさを rMin → rMax まで変える。
向き(rot)と seed も少しずつ変えるので、同じ種類でも同じ粒が2つと無いことも見える。

  使い方:
    python tools/piece_sheet.py          KV260 版（六角柱あり・棒 1:1:3）
    python tools/piece_sheet.py --ref    参照実装 版（星あり・棒 1:1:6）
"""
import math
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ref_cell as R
import kv_cell as K
from piece_table import KV_PIECES

USE_REF = "--ref" in sys.argv

CELL = 96          # 1マスの画素
NCOL = 6           # 大きさを何段階並べるか

if USE_REF:
    ROWS = [("glass", "色ガラス", 1, 0.09, 0.18), ("rod", "棒", 6, 0.12, 0.22),
            ("star", "星", 3, 0.06, 0.10), ("blob", "丸い塊", 7, 0.09, 0.15),
            ("crescent", "三日月", 8, 0.11, 0.19), ("bead", "ビーズ", 0, 0.04, 0.07),
            ("stone", "天然石", 5, 0.06, 0.10), ("glitter", "ラメ", 2, 0.009, 0.018),
            ("bubble", "気泡", 4, 0.05, 0.08)]
    SHADE = R.shade_piece
else:
    ROWS = [(p[0], p[1], K.KEY_TO_TYPE[p[0]], p[3], p[4]) for p in KV_PIECES]
    SHADE = K.shade_piece


def draw_one(typ, key, r_rel, rot, seed, z=0.7):
    """1マスぶん。r_rel は「そのマスの半分を 1.0 とする大きさ」"""
    pad = 2.6 if key == "glitter" else 1.2
    n = CELL
    ix, iy = np.meshgrid(np.arange(n), np.arange(n))
    # マスの中心を原点に、半径 r_rel の粒を描く
    sx = (ix + 0.5) / n * 2.0 - 1.0
    sy = (iy + 0.5) / n * 2.0 - 1.0
    vqx, vqy = sx / r_rel, sy / r_rel
    ca, sa = math.cos(rot), math.sin(rot)
    qx = ca * vqx - sa * vqy
    qy = sa * vqx + ca * vqy

    col = [v for v in K.hexcol(K.COLORS.get(key, ["#8899ff"])[0])]
    p = {"type": typ, "key": key, "seed": seed, "z": z, "rot": rot, "col": col}
    rgb, a = SHADE(p, qx, qy, vqx, vqy, 0.0)
    src = rgb if typ == 2 else rgb * a[..., None]     # ラメだけプリマルチプライドでない
    # 外は枠の外なので捨てる
    out = np.where((np.abs(vqx) <= pad) & (np.abs(vqy) <= pad), 1.0, 0.0)[..., None]
    return np.clip(src * out, 0.0, 1.0), np.clip(a * out[..., 0], 0.0, 1.0)


def main():
    rows = len(ROWS)
    sheet = np.zeros((rows * CELL, NCOL * CELL, 3))
    sheet[:] = 0.06                                    # 暗い地

    for ri, (key, name, typ, rmin, rmax) in enumerate(ROWS):
        for ci in range(NCOL):
            f = ci / (NCOL - 1.0)
            # マスの中での見かけの大きさ。rMin→rMax の比をそのまま出す
            r_rel = 0.80 * (rmin + (rmax - rmin) * f) / rmax
            rgb, a = draw_one(typ, key, r_rel, rot=0.5 + ci * 0.37, seed=0.13 + ci * 0.17)
            y0, x0 = ri * CELL, ci * CELL
            dst = sheet[y0:y0 + CELL, x0:x0 + CELL]
            dst[:] = rgb + dst * (1.0 - a[..., None])

    img = Image.fromarray((sheet * 255).astype(np.uint8))
    out = "sim/piece_sheet_ref.png" if USE_REF else "sim/piece_sheet.png"
    img.save(out)
    print("%s に出した  (上から: %s)" % (out, " / ".join(r[1] for r in ROWS)))
    print("左から右へ rMin → rMax。向きと seed も1マスごとに変えてある")


if __name__ == "__main__":
    main()
