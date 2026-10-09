# -*- coding: utf-8 -*-
"""ピースを「種類ごとにまとめて描く」と絵がどれだけ変わるかを測る。

段5d-2 で 1 つの枠に 4 個まで詰めるには、**同じ種類のピースが表の中で
連続している**必要がある (プログラムが種類ごとに違うので、1 つの枠には
同じ種類しか入れられない)。

ところが参照実装 renderCell() は **z でソートして奥から描く**。
種類ごとにまとめると重なりの順序が変わる。その差をここで測る。

  z 順        参照実装と同じ。詰まらない
  種類順      詰まる。種類の中は z 順にして、奥行きの違いは保つ

  使い方:  python tools/order_test.py
"""
import math
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


def render_with(parts, order, n=CELL):
    """order で並べ替えてから、奥層・手前層に分けて描く"""
    back_list = [p for p in parts if p["z"] < 0.5]
    front_list = [p for p in parts if p["z"] >= 0.5]
    back_list = order(back_list)
    front_list = order(front_list)

    back = RC.oil_bg(n, 0.0)
    orig = RC.shade_piece
    RC.shade_piece = K.shade_piece
    try:
        RC.draw_parts(back, back_list, n, 0.0)
        front = np.zeros((n, n, 4))
        RC.draw_parts(front, front_list, n, 0.0)
    finally:
        RC.shade_piece = orig
    return back, front


def by_z(lst):
    return sorted(lst, key=lambda p: p["z"])


def by_type_then_z(lst):
    """種類でまとめ、種類の中は z 順。種類の順序は「平均 z が奥のものから」"""
    groups = {}
    for p in lst:
        groups.setdefault(int(p["type"]), []).append(p)
    keys = sorted(groups, key=lambda t: np.mean([q["z"] for q in groups[t]]))
    out = []
    for t in keys:
        out.extend(sorted(groups[t], key=lambda p: p["z"]))
    return out


def by_type_shuffled(lst, rng):
    """種類でまとめるが種類の中は順不同 (いまの pparts.hex に近い)"""
    groups = {}
    for p in lst:
        groups.setdefault(int(p["type"]), []).append(p)
    out = []
    for t in sorted(groups):
        g = groups[t][:]
        rng.shuffle(g)
        out.extend(g)
    return out


def compose(back, front):
    """2 層を重ねた最終の絵 (影は入れない。順序の差だけを見る)"""
    a = front[..., 3:4]
    return np.clip(front[..., :3] + back[..., :3] * (1.0 - a), 0, 1)


def main():
    rng = random.Random(1)
    parts = K.make_parts(rng, False)
    print("ピース %d 個" % len(parts))

    ref_b, ref_f = render_with(parts, by_z)
    ref = compose(ref_b, ref_f)

    cases = [("種類順 (種類の中は z 順)", by_type_then_z),
             ("種類順 (種類の中は順不同)",
              lambda l: by_type_shuffled(l, random.Random(7)))]

    for name, order in cases:
        b, f = render_with(parts, order)
        img = compose(b, f)
        d = np.abs(img - ref)
        # 参照実装そのものとの差 (2層合成後) は 9.34/255 だったので、それと比べる
        print("  %-26s 平均 %.3f/255  最大 %.1f/255  0.5/255 を超える画素 %.2f%%"
              % (name, d.mean() * 255, d.max() * 255,
                 100.0 * (d.max(axis=2) > 0.5 / 255).mean()))
        Image.fromarray((img * 255).astype(np.uint8)).save(
            os.path.join(ROOT, "sim", "order_%s.png"
                         % ("type_z" if order is by_type_then_z else "type_rand")))

    Image.fromarray((ref * 255).astype(np.uint8)).save(
        os.path.join(ROOT, "sim", "order_z.png"))
    print("  sim/order_z.png (z順) / order_type_z.png / order_type_rand.png")


if __name__ == "__main__":
    main()
