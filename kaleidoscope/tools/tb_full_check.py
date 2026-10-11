# -*- coding: utf-8 -*-
"""実際のピース表 (rtl/pparts.hex) を丸ごと流して、2 層とも正解と比べる。

段5d-5 から奥層も手前層も PL が描く。`tb_seq_check.py` は作った試験用の
ピースを少数流すが、こちらは **実機と同じ 271 個の表をそのまま**流して、
セル 2 枚の中身を参照実装の正解と突き合わせる。

  奥層  油の地 + z < 0.5 のピース        RGB565
  手前層 z >= 0.5 のピース (透明から)    {ablur, a, rgb565}

  使い方:  python tools/tb_full_check.py
"""
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
import gen_pparts as GP
import tb_seq_check as T

CELL = 256
WORDS = 24


def main():
    # ---- 表を読み、同じ並びで正解を作る ----
    import random
    rng = random.Random(3)
    parts = K.make_parts(rng, False)
    rng.shuffle(parts)
    sel = [p for p in parts if GP.piece_words(p)]
    sel = GP.order_by_type_then_z(sel)
    n = len(sel)
    print("ピース %d 個 (奥層 %d / 手前層 %d)"
          % (n, sum(1 for p in sel if p["z"] < 0.5),
             sum(1 for p in sel if p["z"] >= 0.5)))

    os.makedirs(WORK, exist_ok=True)
    with open(os.path.join(WORK, "seq_in.hex"), "w") as f:
        f.write("%06x\n" % n)
        for p in sel:
            for v in GP.piece_words(p):
                f.write("%06x\n" % (v & 0xFFFFFF))

    # 奥層の下地は油の地
    bg565 = T.oil_background()
    with open(os.path.join(WORK, "seq_bg.hex"), "w") as f:
        for v in bg565.reshape(-1):
            f.write("%04x\n" % v)

    for h in ("pprog.hex", "pprog_base.hex", "pprog_len.hex", "pprog_pre.hex",
              "log2_lut.hex", "exp2_lut.hex", "atan_lut.hex"):
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
        ("pcordic.v", "ptrans.v", "pshade_lane.v", "ppixgen.v", "pshade_seq.v")] +
       [os.path.join(ROOT, "sim", "tb_seq.v")])
    sh([os.path.join(VIV, "xelab.bat"), "-debug", "off", "-timescale", "1ns/1ps",
        "tb_seq", "-s", "snap_seq"])
    for nm in ("seq_out.txt", "seq_outf.txt"):
        p = os.path.join(WORK, nm)
        if os.path.exists(p):
            os.remove(p)
    r = sh([os.path.join(VIV, "xsim.bat"), "snap_seq", "-runall"])
    for ln in (r.stdout or "").split("\n"):
        if "PROBE" in ln or "クロック" in ln or "STUCK" in ln:
            print("  " + ln.strip())

    # ---- RTL が描いた 2 枚 ----
    got_b = T.from565(bg565.copy())
    for ln in open(os.path.join(WORK, "seq_out.txt")):
        a, v = ln.split()
        i, c = int(a), int(v, 16)
        got_b[i >> 8, i & 0xFF] = T.from565(np.array(c))
    got_f = np.zeros((CELL, CELL, 3))
    got_fa = np.zeros((CELL, CELL))
    for ln in open(os.path.join(WORK, "seq_outf.txt")):
        a, v = ln.split()
        i, c = int(a), int(v, 16)
        y, x = i >> 8, i & 0xFF
        got_f[y, x] = T.from565(np.array(c & 0xFFFF))
        got_fa[y, x] = ((c >> 16) & 255) / 255.0

    # ---- 正解 (同じ並びで描く) ----
    orig = RC.shade_piece
    RC.shade_piece = K.shade_piece
    try:
        # ★ 下地も RTL と同じ RGB565 の量子化を通す。
        #   float のままだと、ピースの無い所でも量子化のぶんだけ差が出て、
        #   描画そのものの良否が見えなくなる (平均 1.95 → 下の実測を見よ)
        wb = RC.oil_bg(CELL, 0.0)
        wb[..., :3] = T.from565(bg565)
        RC.draw_parts(wb, [p for p in sel if p["z"] < 0.5], CELL, 0.0)
        wf = np.zeros((CELL, CELL, 4))
        RC.draw_parts(wf, [p for p in sel if p["z"] >= 0.5], CELL, 0.0)
    finally:
        RC.shade_piece = orig
    want_b = np.clip(wb[..., :3], 0, 1)
    want_f = np.clip(wf[..., :3], 0, 1)
    want_fa = np.clip(wf[..., 3], 0, 1)

    db = np.abs(got_b - want_b)
    df = np.abs(got_f - want_f)
    da = np.abs(got_fa - want_fa)
    print("")
    print("  奥層   平均 %.2f / 255   最大 %.1f / 255"
          % (db.mean() * 255, db.max() * 255))
    print("  手前層 平均 %.2f / 255   最大 %.1f / 255"
          % (df.mean() * 255, df.max() * 255))
    print("  α      平均 %.2f / 255   最大 %.1f / 255"
          % (da.mean() * 255, da.max() * 255))
    print("")
    print("  RGB565 の 1 階調は 8.2/255。最大がその程度なら量子化だけ。")

    # 2 層を重ねた最終の絵
    a = want_fa[..., None]
    fin_want = np.clip(want_f + want_b * (1 - a), 0, 1)
    a2 = got_fa[..., None]
    fin_got = np.clip(got_f + got_b * (1 - a2), 0, 1)
    d = np.abs(fin_got - fin_want)
    print("  2 層を重ねた絵: 平均 %.2f / 255   最大 %.1f / 255"
          % (d.mean() * 255, d.max() * 255))

    sheet = np.concatenate([fin_got, fin_want, np.clip(d * 6, 0, 1)], axis=1)
    p = os.path.join(ROOT, "sim", "full_cmp.png")
    Image.fromarray((sheet * 255).astype(np.uint8)).save(p)
    print("  sim/full_cmp.png  左=RTL 中=正解 右=差(6倍)")


if __name__ == "__main__":
    main()
