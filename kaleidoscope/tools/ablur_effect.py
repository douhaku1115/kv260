# -*- coding: utf-8 -*-
"""影用のぼかし α (ablur) をぼかさなかったら絵がどれだけ変わるかを測る。

手前層は 32bit {ablur, a, rgb565} で、`ablur` は **α を 2x2 で平均したもの**
(`tools/cell_from_dump.py` の `uniform_filter(size=2)`)。
参照実装が手前層の影を奥層に落とすときに使う。

段5d-5 で手前層も PL で描くとき、このぼかしを作るには
**セル全体をもう一度なめるパス**が要る (65536 画素の読み書き)。
ぼかさずに `ablur = a` で済むなら、その回路がまるごと要らない。

  使い方:  python tools/ablur_effect.py
"""
import os
import random
import sys

import numpy as np
from PIL import Image
from scipy.ndimage import uniform_filter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)

import kv_cell as K
import ref_cell as RC

CELL = 256
# 影のずれ。参照実装は (0.012, -0.016) をセル座標で動かす
SHIFT = (0.012, -0.016)


def layers(parts, n=CELL):
    orig = RC.shade_piece
    RC.shade_piece = K.shade_piece
    try:
        back = RC.oil_bg(n, 0.0)
        RC.draw_parts(back, sorted([p for p in parts if p["z"] < 0.5],
                                   key=lambda p: p["z"]), n, 0.0)
        front = np.zeros((n, n, 4))
        RC.draw_parts(front, sorted([p for p in parts if p["z"] >= 0.5],
                                    key=lambda p: p["z"]), n, 0.0)
    finally:
        RC.shade_piece = orig
    return back, front


def shift_map(a, n=CELL):
    """影は α を (0.012,-0.016) ずらした位置から引く。セル座標 → 画素"""
    dx = int(round(SHIFT[0] * 0.5 * n))
    dy = int(round(SHIFT[1] * 0.5 * n))
    return np.roll(np.roll(a, -dy, axis=0), -dx, axis=1)


def compose(back, front, shadow_a):
    """C1 影で奥層を暗くする → C2 α 合成 (rtl_top.v と同じ式)"""
    b = np.clip(back[..., :3], 0, 1) * (1.0 - 0.5 * shadow_a[..., None])
    a = np.clip(front[..., 3:4], 0, 1)
    return np.clip(np.clip(front[..., :3], 0, 1) + b * (1.0 - a), 0, 1)


def main():
    rng = random.Random(1)
    parts = K.make_parts(rng, False)
    back, front = layers(parts)
    a = np.clip(front[..., 3], 0, 1)

    # 参照実装と同じ: 2x2 で平均したものを影に使う
    ablur = uniform_filter(a, size=max(2, 8 * CELL // 1024))
    img_blur = compose(back, front, shift_map(ablur))
    # ぼかさない: α をそのまま影に使う
    img_raw = compose(back, front, shift_map(a))

    d = np.abs(img_blur - img_raw)
    dm = d.max(axis=2)
    print("ピース %d 個、セル %dx%d" % (len(parts), CELL, CELL))
    print("  ぼかす(正解) と ぼかさない の差")
    print("    平均 %.3f / 255   最大 %.1f / 255" % (d.mean() * 255, d.max() * 255))
    for th in (1, 2, 4, 8):
        print("    %d/255 を超える画素  %6.3f%%"
              % (th, 100.0 * (dm > th / 255.0).mean()))
    print("")
    print("  参照実装との差はもともと 9.34/255。上の平均と比べること。")
    print("  ぼかしを入れるには、手前層を描いたあとセル全体 (65536 画素) を")
    print("  なめる 1 パスが要る。この差が小さければ ablur = a で済む。")

    sheet = np.concatenate([img_raw, img_blur, np.clip(d * 12, 0, 1)], axis=1)
    p = os.path.join(ROOT, "sim", "ablur_effect.png")
    Image.fromarray((sheet * 255).astype(np.uint8)).save(p)
    print("  sim/ablur_effect.png  左=ぼかさない 中=ぼかす(正解) 右=差(12倍)")


if __name__ == "__main__":
    main()
