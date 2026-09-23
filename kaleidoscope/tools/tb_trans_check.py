# -*- coding: utf-8 -*-
"""表引き (ptrans) を単体で試して、どの演算が合わないかを切り分ける。

  使い方:  python tools/tb_trans_check.py
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

OPNAME = {0: "RECIP", 1: "SQRT", 2: "POW", 3: "EXPN", 4: "SSTEP"}


def fx(v):
    n = int(round(float(v) * ONE))
    n = max(-(1 << 23), min((1 << 23) - 1, n))
    return n & 0xFFFFFF


def unfx(u):
    return (u - (1 << 24) if u & (1 << 23) else u) / ONE


def expect(op, x, a, b):
    if op == 0: return 1.0 / x
    if op == 1: return math.sqrt(x)
    if op == 2: return math.pow(max(x, 0.0), b)
    if op == 3: return math.exp(-x)
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


def main():
    cases = []
    for x in (0.05, 0.2, 0.5, 0.75, 1.0, 1.5, 2.0, 5.0, 12.0):
        cases.append((0, x, 0.0, 0.0))            # RECIP
        cases.append((1, x, 0.0, 0.0))            # SQRT
        cases.append((3, x, 0.0, 0.0))            # EXPN
    for x in (0.1, 0.3, 0.5, 0.7, 0.9, 0.99):
        for n in (3.0, 12.0, 14.0, 24.0, 40.0):
            cases.append((2, x, 0.0, n))          # POW
    for x in (-0.5, 0.0, 0.3, 0.6, 1.0, 1.4):
        cases.append((4, x, 0.0, 1.0))            # SSTEP
        cases.append((4, x, -0.05, 0.05))

    os.makedirs(WORK, exist_ok=True)
    with open(os.path.join(WORK, "trans_in.hex"), "w") as f:
        f.write("%06x\n000000\n000000\n000000\n" % len(cases))
        for op, x, a, b in cases:
            f.write("%06x\n%06x\n%06x\n%06x\n" % (op, fx(x), fx(a), fx(b)))

    for h in ("log2_lut.hex", "exp2_lut.hex"):
        with open(os.path.join(ROOT, "rtl", h)) as s, open(os.path.join(WORK, h), "w") as d:
            d.write(s.read())

    def run(cmd):
        r = subprocess.run(cmd, cwd=WORK, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        if r.returncode:
            print((r.stdout or "")[-3000:])
            sys.exit(1)

    run([os.path.join(VIV, "xvlog.bat"), os.path.join(ROOT, "rtl", "ptrans.v"),
         os.path.join(ROOT, "sim", "tb_trans.v")])
    run([os.path.join(VIV, "xelab.bat"), "-debug", "off", "-timescale", "1ns/1ps",
         "tb_trans", "-s", "snap_trans"])
    out_path = os.path.join(WORK, "trans_out.txt")
    if os.path.exists(out_path):
        os.remove(out_path)
    run([os.path.join(VIV, "xsim.bat"), "snap_trans", "-runall"])

    got = [unfx(int(l, 16)) for l in open(out_path)]

    # 判定は絶対誤差で見る。S6.17 の分解能は 1/131072 = 7.6e-6 なので、
    # それより小さい期待値は 0 になるのが正しく、相対誤差で見ると 100% に見えてしまう。
    LSB = 1.0 / (1 << FRAC)
    worst = {}
    print("  命令    最悪の絶対誤差   そのときの x    期待値      RTL       LSB の何倍")
    for (op, x, a, b), g in zip(cases, got):
        e = expect(op, x, a, b)
        d = abs(g - e)
        k = OPNAME[op]
        if k not in worst or d > worst[k][0]:
            worst[k] = (d, x, b, e, g)
    ok = True
    for k, (d, x, b, e, g) in worst.items():
        n = d / LSB
        bad = n > 40                      # 40 LSB = 色にして 0.08/255
        ok &= not bad
        print("  %-6s  %10.2e      %7.3f   %9.5f  %9.5f   %6.1f%s"
              % (k, d, x, e, g, n, "   ← 合わない" if bad else ""))
    print("\n  %s" % ("すべて許せる範囲" if ok else "★ 合わないものがある"))


if __name__ == "__main__":
    main()
