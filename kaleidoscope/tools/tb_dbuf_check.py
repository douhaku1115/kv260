# -*- coding: utf-8 -*-
"""二重バッファで 2 回描き直す (sim/tb_dbuf.v) を走らせて採点する。段5d-7。

  表 1 = 実機と同じ並び (乱数 3)
  表 2 = 3 つの乱数 (7, 11, 13) の表をつないだ約 1800 個。段6b で上限を 645 → 2048 に
         広げたので、645 個を超えた先まで書けて描けるかを見る
  表は焼き込みではなく、pdriver の書き込み口 (段6b から別クロック) から入れる。

それぞれの描き直しのあと、映す面 (奥層・手前層) を正解と比べる。
下地は PL の ROM (rtl/cell_oil.hex) なので、正解の下地もそこから作る。

  使い方:  python tools/tb_dbuf_check.py
"""
import os
import random
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
import gen_pparts as GP
import tb_seq_check as T

CELL = 256


def make_table(seed):
    rng = random.Random(seed)
    parts = K.make_parts(rng, False)
    rng.shuffle(parts)
    sel = [p for p in parts if GP.piece_words(p)]
    return GP.order_by_type_then_z(sel)


def write_table(path, sel):
    with open(path, "w") as f:
        f.write("%06x\n" % len(sel))
        for p in sel:
            for v in GP.piece_words(p):
                f.write("%06x\n" % (v & 0xFFFFFF))


def read_oil():
    v = [int(l, 16) for l in open(os.path.join(ROOT, "rtl", "cell_oil.hex")) if l.strip()]
    return np.array(v, dtype=np.int64).reshape(CELL, CELL)


def want_layers(sel, bg565):
    orig = RC.shade_piece
    RC.shade_piece = K.shade_piece
    try:
        wb = RC.oil_bg(CELL, 0.0)
        wb[..., :3] = T.from565(bg565)
        RC.draw_parts(wb, [p for p in sel if p["z"] < 0.5], CELL, 0.0)
        wf = np.zeros((CELL, CELL, 4))
        RC.draw_parts(wf, [p for p in sel if p["z"] >= 0.5], CELL, 0.0)
    finally:
        RC.shade_piece = orig
    return (np.clip(wb[..., :3], 0, 1), np.clip(wf[..., :3], 0, 1),
            np.clip(wf[..., 3], 0, 1))


def got_layers(fb, ff):
    got_b = np.zeros((CELL, CELL, 3))
    for ln in open(os.path.join(WORK, fb)):
        a, v = ln.split()
        i, c = int(a), int(v, 16)
        got_b[i >> 8, i & 0xFF] = T.from565(np.array(c))
    got_f = np.zeros((CELL, CELL, 3))
    got_fa = np.zeros((CELL, CELL))
    for ln in open(os.path.join(WORK, ff)):
        a, v = ln.split()
        i, c = int(a), int(v, 16)
        y, x = i >> 8, i & 0xFF
        got_f[y, x] = T.from565(np.array(c & 0xFFFF))
        got_fa[y, x] = ((c >> 16) & 255) / 255.0
    return got_b, got_f, got_fa


def score(name, got, want):
    gb, gf, ga = got
    wb, wf, wa = want
    db, df, da = np.abs(gb - wb), np.abs(gf - wf), np.abs(ga - wa)
    fin_w = np.clip(wf + wb * (1 - wa[..., None]), 0, 1)
    fin_g = np.clip(gf + gb * (1 - ga[..., None]), 0, 1)
    d = np.abs(fin_g - fin_w)
    print("  %s  奥層 %.2f (最大 %.1f)  手前層 %.2f (最大 %.1f)  α %.2f  "
          "2 層を重ねた絵 %.2f (最大 %.1f)  [/255]"
          % (name, db.mean() * 255, db.max() * 255, df.mean() * 255, df.max() * 255,
             da.mean() * 255, d.mean() * 255, d.max() * 255))
    return fin_g, fin_w, d


def main():
    t1 = make_table(3)
    t2 = GP.order_by_type_then_z(make_table(7) + make_table(11) + make_table(13))
    print("表 1: %d 個   表 2: %d 個" % (len(t1), len(t2)))
    os.makedirs(WORK, exist_ok=True)
    write_table(os.path.join(WORK, "tbl1.hex"), t1)
    write_table(os.path.join(WORK, "tbl2.hex"), t2)
    for h in ("pprog.hex", "pprog_base.hex", "pprog_len.hex", "pprog_pre.hex",
              "log2_lut.hex", "exp2_lut.hex", "atan_lut.hex", "cell_oil.hex",
              "pparts.hex"):
        with open(os.path.join(ROOT, "rtl", h)) as a, \
                open(os.path.join(WORK, h), "w") as b:
            b.write(a.read())

    def sh(cmd):
        r = subprocess.run(cmd, cwd=WORK, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        if r.returncode:
            print((r.stdout or "")[-3000:])
            sys.exit(1)
        return r

    sh([os.path.join(VIV, "xvlog.bat"), "-i", os.path.join(ROOT, "rtl")] +
       [os.path.join(ROOT, "rtl", x) for x in
        ("pcordic.v", "ptrans.v", "pshade_lane.v", "ppixgen.v", "pshade_seq.v",
         "pdriver.v", "cell_uram.v", "cell_dbuf.v")] +
       [os.path.join(ROOT, "sim", "tb_dbuf.v")])
    sh([os.path.join(VIV, "xelab.bat"), "-debug", "off", "-timescale", "1ns/1ps",
        "tb_dbuf", "-s", "snap_dbuf"])
    for nm in ("dbuf1_b.txt", "dbuf1_f.txt", "dbuf2_b.txt", "dbuf2_f.txt"):
        p = os.path.join(WORK, nm)
        if os.path.exists(p):
            os.remove(p)
    r = sh([os.path.join(VIV, "xsim.bat"), "snap_dbuf", "-runall"])
    for ln in (r.stdout or "").split("\n"):
        if "DBUF" in ln:
            print("  " + ln.strip())

    bg = read_oil()
    print("")
    rows = []
    for name, sel, fb, ff in (("描き直し 1", t1, "dbuf1_b.txt", "dbuf1_f.txt"),
                              ("描き直し 2", t2, "dbuf2_b.txt", "dbuf2_f.txt")):
        g, w, d = score(name, got_layers(fb, ff), want_layers(sel, bg))
        rows.append(np.concatenate([g, w, np.clip(d * 6, 0, 1)], axis=1))
    print("")
    print("  RGB565 の 1 階調は 8.2/255。最大がその程度なら量子化だけ。")
    p = os.path.join(ROOT, "sim", "dbuf_cmp.png")
    Image.fromarray((np.concatenate(rows, axis=0) * 255).astype(np.uint8)).save(p)
    print("  sim/dbuf_cmp.png  上=描き直し 1 / 下=描き直し 2   左=RTL 中=正解 右=差(6倍)")


if __name__ == "__main__":
    main()
