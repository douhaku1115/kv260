# -*- coding: utf-8 -*-
"""座標を作る部分 (ppixgen) の RTL と Python を突き合わせる。

確かめたいのは「行をまたぐときの折り返し」。レーン k は k, k+8, k+16 … 番目の
画素を受け持ち、行が尽きたら次の行の頭へ回る。ここがずれると、
ピースの右端と左端が入れ替わったような絵になる。

  使い方:  python tools/tb_pixgen_check.py
"""
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
WORK = os.path.join(ROOT, "simbuild")
VIV = "E:/vivado/2025.2/Vivado/bin"
FRAC = 17
ONE = float(1 << FRAC)
LANES = 8
CELL = 256


def fx(v):
    n = int(round(float(v) * ONE))
    n = max(-(1 << 23), min((1 << 23) - 1, n))
    return n & 0xFFFFFF


def unfx(u):
    return (u - (1 << 24) if u & (1 << 23) else u) / ONE


def case(px, py, r, rot, pad, n=CELL):
    """1 つのピースぶんの設定と、Python 側の正解を作る"""
    half = r * pad
    x0 = max(int(math.floor((px - half + 1.0) * 0.5 * n)), 0)
    x1 = min(int(math.ceil((px + half + 1.0) * 0.5 * n)), n)
    y0 = max(int(math.floor((py - half + 1.0) * 0.5 * n)), 0)
    y1 = min(int(math.ceil((py + half + 1.0) * 0.5 * n)), n)
    w = max(x1 - x0, LANES)          # 幅は LANES 以上に丸める
    h = max(y1 - y0, 1)

    inv_r = 1.0 / r
    sx = (2.0 / n) * inv_r           # x が 1 進むときの vqx の増分
    sy = (2.0 / n) * inv_r
    ca, sa = math.cos(rot), math.sin(rot)

    def sxy(ix, iy):
        s_x = (x0 + ix + 0.5) / n * 2.0 - 1.0
        s_y = (y0 + iy + 0.5) / n * 2.0 - 1.0
        vqx = (s_x - px) * inv_r
        vqy = (s_y - py) * inv_r
        return vqx, vqy, ca * vqx - sa * vqy, sa * vqx + ca * vqy

    vqx0, vqy0, qx0, qy0 = sxy(0, 0)
    cfg = dict(bw=w, npix=w * h,
               vqx0=vqx0, vqy0=vqy0, qx0=qx0, qy0=qy0,
               sx_vqx=sx, sy_vqy=sy,
               sx_qx=ca * sx, sy_qx=-sa * sy,
               sx_qy=sa * sx, sy_qy=ca * sy)

    # 正解: 走査順に並べた (vqx, vqy, qx, qy)
    want = [sxy(i % w, i // w) for i in range(w * h)]
    return cfg, want, w, h


def run(cfg, nstep):
    os.makedirs(WORK, exist_ok=True)
    order = ["bw", "npix", "vqx0", "vqy0", "qx0", "qy0",
             "sx_vqx", "sy_vqy", "sx_qx", "sy_qx", "sx_qy", "sy_qy"]
    with open(os.path.join(WORK, "pixgen_in.hex"), "w") as f:
        for k in order:
            v = cfg[k]
            f.write("%06x\n" % (v if isinstance(v, int) else fx(v)))
        f.write("%06x\n" % nstep)
        f.write("000000\n000000\n000000\n")

    def sh(cmd):
        r = subprocess.run(cmd, cwd=WORK, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        if r.returncode:
            print((r.stdout or "")[-3000:])
            sys.exit(1)

    sh([os.path.join(VIV, "xvlog.bat"), os.path.join(ROOT, "rtl", "ppixgen.v"),
        os.path.join(ROOT, "sim", "tb_pixgen.v")])
    sh([os.path.join(VIV, "xelab.bat"), "-debug", "off", "-timescale", "1ns/1ps",
        "tb_pixgen", "-s", "snap_pixgen"])
    out = os.path.join(WORK, "pixgen_out.txt")
    if os.path.exists(out):
        os.remove(out)
    sh([os.path.join(VIV, "xsim.bat"), "snap_pixgen", "-runall"])

    got = []
    for ln in open(out):
        v, a, b, c, d = ln.split()
        got.append((int(v), unfx(int(a, 16)), unfx(int(b, 16)),
                    unfx(int(c, 16)), unfx(int(d, 16))))
    return got


def main():
    tests = [
        ("大きいピース",   0.10, -0.05, 0.22, 0.9, 1.2),
        ("細いピース",     -0.3,  0.4,  0.09, 2.1, 1.2),
        ("ラメ (小さい)",   0.5, -0.5,  0.012, 0.3, 2.6),
        ("端にかかる",     0.88,  0.0,  0.20, 1.7, 1.2),
    ]
    print("  場合            枠      画素   最大の差")
    bad = 0
    for name, px, py, r, rot, pad in tests:
        cfg, want, w, h = case(px, py, r, rot, pad)
        nstep = (len(want) + LANES - 1) // LANES
        got = run(cfg, nstep)

        worst = 0.0
        nvalid = 0
        for s in range(nstep):
            for k in range(LANES):
                v, vqx, vqy, qx, qy = got[s * LANES + k]
                idx = s * LANES + k
                if idx < len(want):
                    if not v:
                        print("    ★ 画素 %d が無効になっている" % idx)
                        bad += 1
                    nvalid += 1
                    e = max(abs(vqx - want[idx][0]), abs(vqy - want[idx][1]),
                            abs(qx - want[idx][2]), abs(qy - want[idx][3]))
                    worst = max(worst, e)
                elif v:
                    print("    ★ 画素 %d が有効になっている (枠の外)" % idx)
                    bad += 1
        ok = worst < 1e-3
        bad += 0 if ok else 1
        print("  %-14s %3dx%-3d %5d   %.2e %s"
              % (name, w, h, len(want), worst, "" if ok else "  ← 合わない"))

    print("\n  %s" % ("すべて一致" if bad == 0 else "★ %d 件が不一致" % bad))


if __name__ == "__main__":
    main()
