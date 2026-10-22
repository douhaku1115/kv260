# -*- coding: utf-8 -*-
"""きらめき層 (rtl/sparkle.v) を tools/sparkle_fx.py と照合する。

本物の折り返し座標 (大きさ 100 と 250) と、範囲の端 (筒の外・負の座標) を混ぜた
20000 画素ぶんの入力と正解を spk_vec.hex に書き、sim/tb_sparkle.v を xsim で回す。
設定 (lv・密度・k・明るさ・時刻) も行ごとに振る。

  使い方:  python tools/tb_sparkle_check.py
"""
import os
import random
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sparkle_fx as F

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
WORK = os.path.join(ROOT, "simbuild", "spk")
VIV = "E:/vivado/2025.2/Vivado/bin"
N = 20000


def coords():
    """本物の折り返し座標を取る (sparkle_layer.fold_uv)。足りない分は乱数"""
    import sparkle_layer as S
    cell = np.zeros((256, 256, 3))
    out = []
    for zoom in (1.0, 2.5):
        _, c, _, _ = S.fold_uv(cell, zoom)
        q = np.clip(np.round(c * 32768.0), -131072, 131071).astype(np.int64)
        out.append(q.reshape(-1, 2))
    q = np.concatenate(out)
    rng = np.random.default_rng(7)
    pick = q[rng.choice(len(q), N - 2000, replace=False)]
    edge = rng.integers(-131072, 131072, size=(2000, 2))       # 範囲の端も試す
    return np.concatenate([pick, edge])


def main():
    os.makedirs(WORK, exist_ok=True)
    F.write_luts(os.path.join(WORK, "spk_fall.hex"), os.path.join(WORK, "spk_tw.hex"))
    q = coords()
    rng = random.Random(11)
    # 色の表 (段7b)。16 個すべて違う色にして、表の引き方の間違いも見つける
    cols = [(rng.randrange(256), rng.randrange(256), rng.randrange(256)) for _ in range(16)]
    with open(os.path.join(WORK, "spk_cols.hex"), "w") as f:
        f.write("\n".join("%02x%02x%02x" % c for c in cols) + "\n")
    lines = []
    lit = 0
    # 設定は段の途中で使われる (dens は P4、k は P7 など)。実機では 1 フレームの間
    # 変わらないので、ここでも BLOCK 画素ごとにしか変えない。切り替わる直前の LAT 画素は
    # 新旧の設定が混ざるので照合しない (bit 131 を立てる)
    BLOCK = 500
    for i in range(N):
        cx, cy = int(q[i, 0]), int(q[i, 1])
        if i % BLOCK == 0:
            lv = rng.choice([3, 4, 5, 6, 7])
            en = 0 if rng.random() < 0.05 else 1
            dens = rng.randrange(256)
            k = rng.choice([rng.randrange(65536), F.params_for_zoom(1.0)[1],
                            F.params_for_zoom(2.5)[1]])
            base, flash, tph = rng.randrange(256), rng.randrange(256), rng.randrange(256)
        skip = 1 if i % BLOCK >= BLOCK - F.LAT else 0
        r, g, b = F.sparkle([cx], [cy], en, lv, dens, k, base, flash, tph, cols)
        r, g, b = int(r[0]), int(g[0]), int(b[0])
        lit += (r | g | b) != 0
        v = (skip << 131) | ((cx & 0x3FFFF) << 113) | ((cy & 0x3FFFF) << 95) | (en << 94) | (lv << 91) | \
            (dens << 83) | (k << 67) | (base << 59) | (flash << 51) | (tph << 43) | \
            (r << 18) | (g << 9) | b
        lines.append("%034x" % v)
    with open(os.path.join(WORK, "spk_vec.hex"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("正解を作った: %d 画素 (光っている画素 %d)" % (N, lit))

    def run(cmd):
        r = subprocess.run(cmd, cwd=WORK, shell=True, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        return r.stdout + r.stderr

    out = run('"%s/xvlog.bat" "%s/rtl/sparkle.v" "%s/sim/tb_sparkle.v"' % (VIV, ROOT, ROOT))
    if "ERROR" in out:
        print(out); sys.exit(1)
    out = run('"%s/xelab.bat" -debug off -timescale 1ns/1ps tb_sparkle -s snap_spk' % VIV)
    if "ERROR" in out:
        print(out); sys.exit(1)
    out = run('"%s/xsim.bat" snap_spk -runall' % VIV)
    for ln in out.splitlines():
        if "照合" in ln or "不一致" in ln or "ERROR" in ln:
            print(ln)


if __name__ == "__main__":
    main()
