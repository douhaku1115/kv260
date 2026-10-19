# -*- coding: utf-8 -*-
"""細かい粒がどれだけ見えているかを測る（段7 の下調べ・段階1）。

  1. 画面の 1 画素がセルの何画素にあたるか (折り返しの式から)
  2. 種類ごとに、1 個がセル (256) 上で何画素ぶん見えるか
       面積 = α の合計、ピーク = α の最大、明るさ = 色 x α の最大
     ピークが小さい (0.5 未満) 粒は、点として見えずに地へ溶ける
  3. 今の構成で「見える粒」が何個あるか

  使い方:  python tools/grain_audit.py
"""
import os
import random
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ref_cell as R
import ref_scope as S
import kv_cell as K
from piece_table import KV_PIECES

CELL = 256


def screen_to_cell(zoom):
    """画面 1 画素ぶん進んだときにセルの何画素進むか (反射しても道のりは同じ)"""
    slope = 1.0 / (S.H * S.FOCAL * zoom)
    return slope * S.Z_CELL / S.TUBE_R * (CELL / 2.0)


def one_piece(p, t=0.0):
    """1 個だけを空のセルに描いて (面積, ピーク α, 最大の明るさ) を返す"""
    buf = np.zeros((CELL, CELL, 4))
    R.draw_parts(buf, [p], CELL, t)
    a = buf[..., 3]
    lum = buf[..., :3].max(-1)
    return a.sum(), a.max(), lum.max()


def main():
    print("【1】画面 1 画素 = セル何画素か")
    for z in (1.0, 0.5, 2.0):
        print("  大きさ %3d: %.2f セル画素  (セル 1 画素 = 画面 %.2f 画素)"
              % (z * 100, screen_to_cell(z), 1.0 / screen_to_cell(z)))
    print()

    orig = R.shade_piece
    R.shade_piece = K.shade_piece
    try:
        rng = random.Random(5)
        print("【2】1 個あたりの見え方 (セル 256 上、各 200 個の平均)")
        print("  種類        個数  半径(画素)    面積   ピークα  明るさ  見える割合")
        tot_vis = 0
        for pc in KV_PIECES:
            key, name, n_def = pc[0], pc[1], pc[7]
            if n_def == 0:
                continue
            area = peak = lum = 0.0
            vis = 0
            m = 200
            for _ in range(m):
                p = K.spawn(pc, rng)
                p["x"], p["y"] = 0.0, 0.0
                a, pk, lm = one_piece(p, t=rng.uniform(0, 6.0))
                area += a; peak += pk; lum += lm
                if pk >= 0.5 and lm >= 0.25:
                    vis += 1
            fr = vis / float(m)
            tot_vis += fr * n_def
            print("  %-8s %6d  %4.1f-%4.1f  %7.1f   %5.2f   %5.2f   %5.0f%%"
                  % (name, n_def, pc[3] * CELL / 2, pc[4] * CELL / 2,
                     area / m, peak / m, lum / m, 100 * fr))
        print()
        print("【3】ピーク α 0.5 以上かつ明るさ 0.25 以上を「見える粒」とすると、約 %d 個" % tot_vis)
    finally:
        R.shade_piece = orig


if __name__ == "__main__":
    main()
