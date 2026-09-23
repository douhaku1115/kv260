# -*- coding: utf-8 -*-
"""KV260 版のピースで作ったセルを、万華鏡の折り返しに通して 1280x720 を出す。

段5c で PL に載せる形が、実際の映像でどう見えるかを確かめるためのもの。
折り返しは `tools/cell_res_test.py` の fold()（浮動小数点の正解実装）をそのまま使う。

  使い方:
    python tools/kv_scope.py             既定 271 個、セル 256
    python tools/kv_scope.py --n 512     セルの解像度を変える
    python tools/kv_scope.py --max       上限 625 個
    python tools/kv_scope.py --ref       参照実装のピースで同じことをする（見比べ用）
"""
import os
import random
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ref_cell as RC
import kv_cell as K
from cell_res_test import fold, shrink


def main():
    n = 512
    if "--n" in sys.argv:
        n = int(sys.argv[sys.argv.index("--n") + 1])
    seed = 1
    if "--seed" in sys.argv:
        seed = int(sys.argv[sys.argv.index("--seed") + 1])
    use_max = "--max" in sys.argv
    use_ref = "--ref" in sys.argv

    # セルは 1024 で描いてから縮める。PL も同じ（高い解像度で描いて落とすのではなく、
    # 直接 n で描く）が、ここでは形の確認が目的なので縮小で代用する
    draw_n = 1024

    if use_ref:
        import json, io
        d = json.load(io.open("ref/dump/parts.json", encoding="utf-8"))
        parts = d["parts"]
        back, front = RC.render_cell(parts, draw_n, 0.0)
        tag = "ref"
    else:
        rng = random.Random(seed)
        parts = K.make_parts(rng, use_max)
        back, front = K.render(parts, draw_n)
        tag = "kv"

    comp = np.clip(front[..., :3] + back[..., :3] * (1.0 - front[..., 3:4]), 0, 1)
    cell = comp if n == draw_n else shrink(comp, n)
    print("ピース %d 個、セル %d で折り返す" % (len(parts), n))

    img = fold(cell)
    out = "sim/scope_%s_%d.png" % (tag, n)
    Image.fromarray((img * 255 + 0.5).astype(np.uint8)).save(out)
    print("%s に出した" % out)


if __name__ == "__main__":
    main()
