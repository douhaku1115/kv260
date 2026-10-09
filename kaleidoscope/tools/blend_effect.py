# -*- coding: utf-8 -*-
"""「下の色に重ねる」(段5d-3) で絵がどれだけ変わるかを測る。

段5c〜5d-2 はピースの色を**上書き**していた。段5d-3 で α 合成にした。
実機では違いが分からなかったので、**どれだけ変わるはずなのか**を
数字で出す。小さければ「分からないのが正常」。

  上書き    α > 0 の画素を、油の地を無視してピースの色で置き換える
            (RTL は「α を掛けた色」を書くので、下の色 0 として扱われる)
  α 合成    参照実装 renderCell() と同じ。これが正解

  使い方:  python tools/blend_effect.py
"""
import os
import random
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)

import kv_cell as K
import ref_cell as RC

CELL = 256


def layers(parts, n=CELL):
    """ピースだけを描いた層 (プリマルチプライド色 + α) を奥・手前で返す"""
    orig = RC.shade_piece
    RC.shade_piece = K.shade_piece
    try:
        out = []
        for lst in ([p for p in parts if p["z"] < 0.5],
                    [p for p in parts if p["z"] >= 0.5]):
            buf = np.zeros((n, n, 4))
            RC.draw_parts(buf, sorted(lst, key=lambda p: p["z"]), n, 0.0)
            out.append(buf)
    finally:
        RC.shade_piece = orig
    return out


def main():
    rng = random.Random(1)
    parts = K.make_parts(rng, False)
    oil = np.clip(RC.oil_bg(CELL, 0.0)[..., :3], 0, 1)
    back, front = layers(parts)

    a_b = np.clip(back[..., 3:4], 0, 1)
    # 奥層: 油の地の上にピース
    blend_back = np.clip(back[..., :3] + oil * (1.0 - a_b), 0, 1)
    # 上書き: α > 0 の画素は地を捨てる
    over_back = np.where(a_b > 0, np.clip(back[..., :3], 0, 1), oil)

    # 手前層は 2 層合成でそのまま重なる (どちらの版でも同じ扱い)
    a_f = np.clip(front[..., 3:4], 0, 1)
    fin_blend = np.clip(front[..., :3] + blend_back * (1.0 - a_f), 0, 1)
    fin_over = np.clip(front[..., :3] + over_back * (1.0 - a_f), 0, 1)

    d = np.abs(fin_blend - fin_over)
    dm = d.max(axis=2)
    print("ピース %d 個、セル %dx%d" % (len(parts), CELL, CELL))
    print("  上書き と α 合成 の差")
    print("    平均 %.3f / 255   最大 %.1f / 255" % (d.mean() * 255, d.max() * 255))
    for th in (1, 4, 8, 16, 32):
        print("    %3d/255 を超える画素  %6.3f%%"
              % (th, 100.0 * (dm > th / 255.0).mean()))
    print("")
    print("  参照実装との差はもともと 9.34/255。上の平均と比べること。")

    sheet = np.concatenate([fin_over, fin_blend, np.clip(d * 6, 0, 1)], axis=1)
    p = os.path.join(ROOT, "sim", "blend_effect.png")
    Image.fromarray((sheet * 255).astype(np.uint8)).save(p)
    print("  sim/blend_effect.png  左=上書き(段5d-2まで) 中=α合成(段5d-3) 右=差(6倍)")


if __name__ == "__main__":
    main()
