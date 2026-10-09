# -*- coding: utf-8 -*-
"""段5c を実機で見るための焼き込みデータを2つ作る。

  rtl/cell_oil.hex   ピースを描いていない油の地だけのセル画像 (奥層の初期値)
  rtl/pparts.hex     ピースの表。並び替え器がそのまま読める形にしてある

最小版では AXI を使わない。PL が起動後に表を頭から順に読み、
油の地の上へピースを描く。これで「PL がピースを描いて HDMI に出る」ことだけ
を確かめる。動かす (物理演算で毎フレーム書き換える) のは次の段。

1 個あたり 24 語 x 24bit。並びは rtl/pshade_seq.v の入り口と同じ。

  使い方:  python tools/gen_pparts.py [個数]
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
from piece_table import KV_PIECES

FRAC = 17
ONE = float(1 << FRAC)
CELL = 256
LANES = 8
WORDS = 24            # 1 個あたりの語数


def fx(v):
    n = int(round(float(v) * ONE))
    n = max(-(1 << 23), min((1 << 23) - 1, n))
    return n & 0xFFFFFF


def piece_words(p):
    """ピース 1 個 → 並び替え器が読む 24 語"""
    key = p["key"]
    typ = K.KEY_TO_TYPE[key]
    pad = 2.6 if key == "glitter" else 1.2
    n = CELL
    r = p["r"] * (0.85 + 0.3 * p["z"])          # 奥行きで大きさが変わる
    half = r * pad
    x0 = int(math.floor((p["x"] - half + 1.0) * 0.5 * n))
    x1 = int(math.ceil((p["x"] + half + 1.0) * 0.5 * n))
    y0 = int(math.floor((p["y"] - half + 1.0) * 0.5 * n))
    y1 = int(math.ceil((p["y"] + half + 1.0) * 0.5 * n))
    x0, y0 = max(x0, 0), max(y0, 0)
    x1, y1 = min(x1, n), min(y1, n)
    w = max(x1 - x0, LANES)
    h = max(y1 - y0, 1)
    if x0 + w > n:                               # 幅を丸めた結果はみ出したら寄せる
        x0 = n - w
    if y0 + h > n:
        y0 = n - h
    if w <= 0 or h <= 0:
        return None

    inv_r = 1.0 / r
    s = (2.0 / n) * inv_r
    ca, sa = math.cos(p["rot"]), math.sin(p["rot"])
    sx = (x0 + 0.5) / n * 2.0 - 1.0
    sy = (y0 + 0.5) / n * 2.0 - 1.0
    vqx0 = (sx - p["x"]) * inv_r
    vqy0 = (sy - p["y"]) * inv_r
    qx0 = ca * vqx0 - sa * vqy0
    qy0 = sa * vqx0 + ca * vqy0

    e = 0.1 + (0.025 - 0.1) * p["z"]
    depth = 0.65 + 0.35 * p["z"]
    col = p["col"]
    premul = 1 if key in ("glitter", "bubble") else 0

    return [typ, w, w * h, x0, y0,
            fx(vqx0), fx(vqy0), fx(qx0), fx(qy0),
            fx(s), fx(s), fx(ca * s), fx(-sa * s), fx(sa * s), fx(ca * s),
            fx(p["seed"]), fx(e), fx(p["rot"]), fx(0.0),
            int(col[0] * 255 + .5), int(col[1] * 255 + .5), int(col[2] * 255 + .5),
            fx(depth), premul]


def order_by_type_then_z(lst):
    """種類でまとめ、種類の中は z 順。種類の順序は「平均 z が奥のものから」。

    枠に詰めるために同じ種類を隣り合わせる。奥行きの前後は種類の中で保つ。
    tools/order_test.py が、この並びと参照実装の z 順との差を測る。
    """
    groups = {}
    for p in lst:
        groups.setdefault(int(p["type"]), []).append(p)
    keys = sorted(groups,
                  key=lambda t: sum(q["z"] for q in groups[t]) / len(groups[t]))
    out = []
    for t in keys:
        out.extend(sorted(groups[t], key=lambda p: p["z"]))
    return out


def main():
    want = int(sys.argv[1]) if len(sys.argv) > 1 else 64
    rng = random.Random(3)

    # ---- 油の地だけのセル画像 ----
    bg = RC.oil_bg(CELL, 0.0)[..., :3]
    rgb565 = (((np.clip(bg[..., 0], 0, 1) * 31 + .5).astype(int) << 11) |
              ((np.clip(bg[..., 1], 0, 1) * 63 + .5).astype(int) << 5) |
              ((np.clip(bg[..., 2], 0, 1) * 31 + .5).astype(int)))
    with open(os.path.join(ROOT, "rtl", "cell_oil.hex"), "w") as f:
        for v in rgb565.reshape(-1):
            f.write("%04x\n" % v)
    print("  rtl/cell_oil.hex    油の地だけ %dx%d" % (CELL, CELL))

    # ---- ピースの表 ----
    #   既定の内訳をそのまま縮めて want 個にする
    parts = K.make_parts(rng, False)
    rng.shuffle(parts)
    sel = []
    for p in parts:
        if len(sel) >= want:
            break
        if piece_words(p):
            sel.append(p)

    # ★ 種類ごとにまとめ、種類の中は z 順にする。
    #   並び替え器は 1 つの枠に同じ種類を 4 個まで詰める (プログラムが
    #   種類ごとに違うので、違う種類は同じ枠に入れられない)。
    #   表がばらばらだと詰まらず、ただ遅くなる。
    #
    #   参照実装 renderCell() は z だけでソートして奥から描く。種類で
    #   まとめると重なりの順序が変わるが、**種類の中を z 順に保てば**
    #   差は平均 0.285/255 しかない (tools/order_test.py で実測。
    #   参照実装との差はもともと 9.34/255 あるので埋もれる)。
    #   種類の中を順不同にすると 1.789/255 で 6 倍悪くなるので、
    #   z 順は守ること。
    sel = order_by_type_then_z(sel)
    out = [piece_words(p) for p in sel]
    used = sel
    with open(os.path.join(ROOT, "rtl", "pparts.hex"), "w") as f:
        for wlist in out:
            for v in wlist:
                f.write("%06x\n" % (v & 0xFFFFFF))
    print("  rtl/pparts.hex      %d 個 x %d 語" % (len(out), WORDS))

    cnt = {}
    for p in used:
        cnt[p["key"]] = cnt.get(p["key"], 0) + 1
    nm = {q[0]: q[1] for q in KV_PIECES}
    print("  内訳: " + "  ".join("%s %d" % (nm[k], v) for k, v in sorted(cnt.items())))

    # ---- 期待される絵 (実機と見比べる用) ----
    back, front = K.render(used, CELL)
    Image.fromarray((np.clip(back[..., :3], 0, 1) * 255).astype(np.uint8)).save(
        os.path.join(ROOT, "sim", "pparts_expect.png"))
    print("  sim/pparts_expect.png  実機と見比べる絵")


if __name__ == "__main__":
    main()
