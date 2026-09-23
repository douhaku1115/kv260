# -*- coding: utf-8 -*-
"""並び替え器が描いたピース 1 個を、Python の正解と突き合わせる。

これが合えば「座標を作る → 演算器で陰影を出す → セルへ重ねる」の
一本の流れが通ったことになる。合成に進んでよい合図。

  使い方:  python tools/tb_seq_check.py [種類]
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
    meta = dict(x0=x0, y0=y0, w=w, h=h, typ=typ, key=key, px=px, py=py, r=r,
                rot=rot, seed=seed, z=z, col=col, premul=premul, depth=depth)
    return cfg, meta


def want_image(m):
    """Python 側で同じピースを 1 個描く (黒地の上に重ねる)"""
    n = CELL
    buf = np.zeros((n, n, 4))
    p = {"type": m["typ"], "key": m["key"], "x": m["px"], "y": m["py"],
         "r": m["r"] / (0.85 + 0.3 * m["z"]),     # draw_parts が掛け戻すので割っておく
         "z": m["z"], "rot": m["rot"], "seed": m["seed"], "col": m["col"]}
    orig = RC.shade_piece
    RC.shade_piece = K.shade_piece
    try:
        RC.draw_parts(buf, [p], n, 0.0)
    finally:
        RC.shade_piece = orig
    return np.clip(buf[..., :3], 0, 1)


def main():
    key = sys.argv[1] if len(sys.argv) > 1 else "glass"
    cfg, m = build_case(key, px=0.1, py=-0.05, r=0.18, rot=0.7, seed=0.37, z=0.7)

    os.makedirs(WORK, exist_ok=True)
    with open(os.path.join(WORK, "seq_in.hex"), "w") as f:
        for v in cfg:
            f.write("%06x\n" % (v & 0xFFFFFF))
        for _ in range(32 - len(cfg)):
            f.write("000000\n")
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
        if "クロック" in ln or "seq_out" in ln:
            print("  " + ln.strip())

    got = np.zeros((CELL, CELL, 3))
    npx = 0
    for ln in open(out):
        a, v = ln.split()
        i, c = int(a), int(v, 16)
        y, x = i >> 8, i & 0xFF
        got[y, x] = [((c >> 11) & 31) / 31.0, ((c >> 5) & 63) / 63.0, (c & 31) / 31.0]
        npx += 1

    want = want_image(m)
    d = np.abs(got - want)
    print("  種類 %s   枠 %dx%d   書いた画素 %d" % (key, m["w"], m["h"], npx))
    print("  平均の差 %.2f / 255   最大 %.2f / 255" % (d.mean() * 255, d.max() * 255))

    sheet = np.concatenate([got, want, np.clip(d * 6, 0, 1)], axis=1)
    sub = sheet[max(m["y0"] - 4, 0):m["y0"] + m["h"] + 4]
    Image.fromarray((np.clip(sheet, 0, 1) * 255).astype(np.uint8)).save("sim/seq_cmp.png")
    print("  sim/seq_cmp.png  左=RTL 中=正解 右=差(6倍)")


if __name__ == "__main__":
    main()
