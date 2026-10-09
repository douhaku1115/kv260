# -*- coding: utf-8 -*-
"""並び替え器が描いたピースを、Python の正解と突き合わせる。

これが合えば「座標を作る → 演算器で陰影を出す → セルへ重ねる」の
一本の流れが通ったことになる。合成に進んでよい合図。

段5d-2 から **1 つの枠に同じ種類のピースを 4 個まで詰める**ようになった。
個数を 2 つめの引数で渡すと、同じ種類をその数だけ重ならない位置に並べ、
seed と rot をすべて違う値にして流す。ピースごとの定数
(seed/e/rot・色・奥行きの暗さ) が枠の中で正しく切り替わるかは
**これでしか確かめられない**。1 個だけだと切り替えが起きないので通ってしまう。

段5d-3 から**下の色を読んで重ねる**ようになった。4 つめの引数に oil を
渡すと、油の地 (rtl/cell_oil.hex) を下地にして流す。黒地だと α の効きが
分からないので、**重ねる実装を確かめるには oil が要る**。

  使い方:  python tools/tb_seq_check.py [種類] [個数] [半径] [oil]
           python tools/tb_seq_check.py glass 4 0.015 oil
           python tools/tb_seq_check.py glitter 4
"""
import math
import os
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
WORK = os.path.join(ROOT, "simbuild")
VIV = "E:/vivado/2025.2/Vivado/bin"
sys.path.insert(0, HERE)

import kv_cell as K
import ref_cell as RC
import piece_table as PT

FRAC = 17
ONE = float(1 << FRAC)
LANES = 8
CELL = 256
WORDS = 24


def fx(v):
    n = int(round(float(v) * ONE))
    n = max(-(1 << 23), min((1 << 23) - 1, n))
    return n & 0xFFFFFF


def build_case(key, px, py, r, rot, seed, z):
    typ = K.KEY_TO_TYPE[key]
    pad = 2.6 if key == "glitter" else 1.2
    n = CELL
    half = r * pad
    x0 = max(int(math.floor((px - half + 1.0) * 0.5 * n)), 0)
    x1 = min(int(math.ceil((px + half + 1.0) * 0.5 * n)), n)
    y0 = max(int(math.floor((py - half + 1.0) * 0.5 * n)), 0)
    y1 = min(int(math.ceil((py + half + 1.0) * 0.5 * n)), n)
    w = max(x1 - x0, LANES)
    h = max(y1 - y0, 1)
    if x0 + w > n:
        x0 = n - w
    inv_r = 1.0 / r
    s = (2.0 / n) * inv_r
    ca, sa = math.cos(rot), math.sin(rot)

    def at(ix, iy):
        sx = (x0 + ix + 0.5) / n * 2.0 - 1.0
        sy = (y0 + iy + 0.5) / n * 2.0 - 1.0
        vqx = (sx - px) * inv_r
        vqy = (sy - py) * inv_r
        return vqx, vqy, ca * vqx - sa * vqy, sa * vqx + ca * vqy

    vqx0, vqy0, qx0, qy0 = at(0, 0)
    e = 0.1 + (0.025 - 0.1) * z
    depth = 0.65 + 0.35 * z
    col = K.hexcol(K.COLORS[key][0])
    premul = 1 if key in ("glitter", "bubble") else 0

    cfg = [typ, w, w * h, x0, y0,
           fx(vqx0), fx(vqy0), fx(qx0), fx(qy0),
           fx(s), fx(s), fx(ca * s), fx(-sa * s), fx(sa * s), fx(ca * s),
           fx(seed), fx(e), fx(rot), fx(0.0),
           int(col[0] * 255 + .5), int(col[1] * 255 + .5), int(col[2] * 255 + .5),
           fx(depth), premul]
    assert len(cfg) == WORDS
    meta = dict(x0=x0, y0=y0, w=w, h=h, typ=typ, key=key, px=px, py=py, r=r,
                rot=rot, seed=seed, z=z, col=col, premul=premul, depth=depth)
    return cfg, meta


def make_cases(key, count, r=None):
    """同じ種類を count 個、重ならない位置に並べる。

    ★ seed / rot / z をすべて違う値にすること。同じにすると、
      枠の中でピースごとの定数が入れ替わらなくても絵が合ってしまい、
      バンクの選択を間違えていても気づけない。

    ★ r を小さくしないと詰まらない。1 枠は LANES*WARP = 192 画素で、
      r=0.12 だと 1 個で枠を何十個も使ってしまう。実物のラメは
      112 画素 (r は 0.016 ぐらい) なので、既定は 0.015 にしてある。
      大きいピースで枠をまたぐ場合を見たいときは r を渡す。
    """
    if count == 1 and r is None:
        return [build_case(key, px=0.1, py=-0.05, r=0.18, rot=0.7, seed=0.37, z=0.7)]
    if r is None:
        r = 0.015

    # 格子に置く。間隔は r の何倍も開いているので重ならない
    spots = [(-0.35, -0.35), (0.35, -0.35), (-0.35, 0.35), (0.35, 0.35),
             (0.0, -0.7), (0.0, 0.7), (-0.7, 0.0), (0.7, 0.0),
             (-0.35, 0.0), (0.35, 0.0), (0.0, -0.35), (0.0, 0.35)]
    out = []
    for i in range(count):
        px, py = spots[i % len(spots)]
        # ★ z は 0〜1 に収める。1 を超えると奥行きの暗さが 1 を超え、
        #   参照実装にも無い値になる (テストの不備で壊れて見える)
        z = 0.15 + 0.75 * (i / float(max(1, count - 1)))
        out.append(build_case(key, px=px, py=py, r=r,
                              rot=0.3 + 0.41 * i,       # 全部違う
                              seed=0.11 + 0.17 * i,     # 全部違う
                              z=z))                     # 奥行きの暗さも違う
    return out


def rgb565(a):
    """RTL がセルに書くのと同じ RGB565 に落として 8bit へ戻す"""
    r = np.clip(a[..., 0], 0, 1)
    g = np.clip(a[..., 1], 0, 1)
    b = np.clip(a[..., 2], 0, 1)
    ri = (r * 31 + 0.5).astype(int)
    gi = (g * 63 + 0.5).astype(int)
    bi = (b * 31 + 0.5).astype(int)
    return (ri << 11) | (gi << 5) | bi


def from565(v):
    """RGB565 を 8bit へ戻す (pshade_seq.v の br_/bg_/bb_ と同じ式)"""
    r = ((v >> 11) & 31)
    g = ((v >> 5) & 63)
    b = (v & 31)
    r8 = (r << 3) | (r >> 2)
    g8 = (g << 2) | (g >> 4)
    b8 = (b << 3) | (b >> 2)
    return np.stack([r8, g8, b8], axis=-1) / 255.0


def oil_background():
    """油の地を RGB565 に量子化したもの (RTL の下地と同じ値)"""
    bg = RC.oil_bg(CELL, 0.0)
    return rgb565(bg[..., :3])


def want_image(metas, bg565=None):
    """Python 側で同じピースを描く。

    bg565 を渡すと、その下地 (RGB565 の 16bit 配列) の上に重ねる。
    ★ 下地は RTL と同じ量子化を通した値を使うこと。float のままだと
      RGB565 の丸めのぶんだけ差が出て、重ねる実装の良否が見えない。
    """
    n = CELL
    buf = np.zeros((n, n, 4))
    ps = []
    for m in metas:
        ps.append({"type": m["typ"], "key": m["key"], "x": m["px"], "y": m["py"],
                   # draw_parts が (0.85+0.3z) を掛け戻すので割っておく
                   "r": m["r"] / (0.85 + 0.3 * m["z"]),
                   "z": m["z"], "rot": m["rot"], "seed": m["seed"], "col": m["col"]})
    orig = RC.shade_piece
    RC.shade_piece = K.shade_piece
    try:
        RC.draw_parts(buf, ps, n, 0.0)
    finally:
        RC.shade_piece = orig
    if bg565 is None:
        return np.clip(buf[..., :3], 0, 1)
    # プリマルチプライド済みの色を、下地に α で重ねる
    under = from565(bg565)
    a = np.clip(buf[..., 3:4], 0, 1)
    return np.clip(buf[..., :3] + under * (1.0 - a), 0, 1)


def main():
    key = sys.argv[1] if len(sys.argv) > 1 else "glass"
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    rad = float(sys.argv[3]) if len(sys.argv) > 3 else None
    use_oil = "oil" in sys.argv[1:]
    cases = make_cases(key, count, rad)
    metas = [m for _, m in cases]

    os.makedirs(WORK, exist_ok=True)
    with open(os.path.join(WORK, "seq_in.hex"), "w") as f:
        f.write("%06x\n" % count)                 # 0 番地 = 個数
        for cfg, _ in cases:
            for v in cfg:
                f.write("%06x\n" % (v & 0xFFFFFF))

    # 下地。oil を渡したら油の地、渡さなければ黒地
    #   ★ 黒地だと α の効きが見えないので、重ねる実装 (段5d-3) を
    #     確かめるには oil が要る
    bg565 = oil_background() if use_oil else None
    with open(os.path.join(WORK, "seq_bg.hex"), "w") as f:
        if bg565 is None:
            f.write("0000\n")                     # 先頭 1 語だけ。残りは 0
        else:
            for v in bg565.reshape(-1):
                f.write("%04x\n" % v)
    for h in ("pprog.hex", "pprog_base.hex", "pprog_len.hex", "pprog_pre.hex",
              "log2_lut.hex", "exp2_lut.hex", "atan_lut.hex"):
        with open(os.path.join(ROOT, "rtl", h)) as a, open(os.path.join(WORK, h), "w") as b:
            b.write(a.read())

    def sh(cmd):
        r = subprocess.run(cmd, cwd=WORK, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        if r.returncode:
            print((r.stdout or "")[-4000:])
            sys.exit(1)
        return r

    sh([os.path.join(VIV, "xvlog.bat"), "-i", os.path.join(ROOT, "rtl")] +
       [os.path.join(ROOT, "rtl", x) for x in
        ("pcordic.v", "ptrans.v", "pshade_lane.v", "ppixgen.v", "pshade_seq.v")] +
       [os.path.join(ROOT, "sim", "tb_seq.v")])
    sh([os.path.join(VIV, "xelab.bat"), "-debug", "off", "-timescale", "1ns/1ps",
        "tb_seq", "-s", "snap_seq"])
    out = os.path.join(WORK, "seq_out.txt")
    if os.path.exists(out):
        os.remove(out)
    r = sh([os.path.join(VIV, "xsim.bat"), "snap_seq", "-runall"])
    for ln in (r.stdout or "").split("\n"):
        if "PROBE" in ln or "クロック" in ln:
            print("  " + ln.strip())

    got = np.zeros((CELL, CELL, 3))
    npx = 0
    for ln in open(out):
        a, v = ln.split()
        i, c = int(a), int(v, 16)
        y, x = i >> 8, i & 0xFF
        got[y, x] = [((c >> 11) & 31) / 31.0, ((c >> 5) & 63) / 63.0, (c & 31) / 31.0]
        npx += 1

    want = want_image(metas, bg565)
    d = np.abs(got - want)
    # 枠の中だけの差も出す。下地は書き換えないので、全画素だと薄まる
    inbox = np.zeros((CELL, CELL), dtype=bool)
    for m in metas:
        inbox[m["y0"]:m["y0"] + m["h"], m["x0"]:m["x0"] + m["w"]] = True
    db = d.max(axis=2)[inbox]
    print("  種類 %s x %d 個   枠 %dx%d   下地 %s   出力した画素 %d"
          % (key, count, metas[0]["w"], metas[0]["h"],
             "油の地" if use_oil else "黒", npx))
    print("  枠の中: 平均 %.2f / 255   最大 %.2f / 255"
          % (db.mean() * 255, db.max() * 255))
    print("  全画素: 平均 %.2f / 255   最大 %.2f / 255"
          % (d.mean() * 255, d.max() * 255))

    sheet = np.concatenate([got, want, np.clip(d * 6, 0, 1)], axis=1)
    Image.fromarray((np.clip(sheet, 0, 1) * 255).astype(np.uint8)).save("sim/seq_cmp.png")
    print("  sim/seq_cmp.png  左=RTL 中=正解 右=差(6倍)")


if __name__ == "__main__":
    main()
