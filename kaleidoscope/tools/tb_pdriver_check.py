# -*- coding: utf-8 -*-
"""pdriver が表の中身をそのまま出すか確かめる。

段5d-5 で pdriver を「24 語を同時に引く」から「1 語ずつ 24 クロックかけて
読む」に変えた（同時引きだと 271 個で LUT が 30769 個増えて配置できない）。
読み方を変えても**中身が 1 語も狂わない**ことを、ここで確かめる。

  使い方:  python tools/tb_pdriver_check.py
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
WORK = os.path.join(ROOT, "simbuild")
VIV = "E:/vivado/2025.2/Vivado/bin"
WORDS = 24


def main():
    # 表をそのまま読む（pdriver が読むのと同じファイル）
    want = []
    with open(os.path.join(ROOT, "rtl", "pparts.hex")) as f:
        vals = [int(ln.strip(), 16) for ln in f if ln.strip()]
    n = len(vals) // WORDS
    for i in range(n):
        want.append(vals[i * WORDS:(i + 1) * WORDS])
    print("表のピース %d 個" % n)

    os.makedirs(WORK, exist_ok=True)
    with open(os.path.join(ROOT, "rtl", "pparts.hex")) as a, \
            open(os.path.join(WORK, "pparts.hex"), "w") as b:
        b.write(a.read())

    def sh(cmd):
        r = subprocess.run(cmd, cwd=WORK, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        if r.returncode:
            print((r.stdout or "")[-3000:])
            sys.exit(1)
        return r

    sh([os.path.join(VIV, "xvlog.bat"), "-i", os.path.join(ROOT, "rtl"),
        os.path.join(ROOT, "rtl", "pdriver.v"),
        os.path.join(ROOT, "sim", "tb_pdriver.v")])
    # ★ -generic_top は Windows のバッチで '=' が壊れる
    #   (CLAUDE.md の -testplusarg と同じ罠)。tb に直接書いてある値を使う
    sh([os.path.join(VIV, "xelab.bat"), "-debug", "off", "-timescale", "1ns/1ps",
        "tb_pdriver", "-s", "snap_drv"])
    out = os.path.join(WORK, "seq_drv.txt")
    if os.path.exists(out):
        os.remove(out)
    r = sh([os.path.join(VIV, "xsim.bat"), "snap_drv", "-runall"])
    for ln in (r.stdout or "").split("\n"):
        if "PDRV" in ln:
            print("  " + ln.strip())

    got = []
    for ln in open(out):
        q = ln.split()
        got.append([int(v, 16) for v in q[1:]])

    print("  出てきた %d 個" % len(got))
    bad = 0
    for i in range(min(len(got), len(want))):
        for k in range(WORDS):
            # 23 語目は premul|front の 2bit だけ比べる
            gv, wv = got[i][k], want[i][k]
            if k == 23:
                gv &= 3
                wv &= 3
            if gv != wv:
                bad += 1
                if bad <= 5:
                    print("    ピース%d 語%d: 表 %06x → 出力 %06x"
                          % (i, k, want[i][k], got[i][k]))
    if len(got) != len(want):
        print("  ★ 個数が違う (表 %d / 出力 %d)" % (len(want), len(got)))
    print("  食い違った語: %d / %d" % (bad, min(len(got), len(want)) * WORDS))
    if bad == 0 and len(got) == len(want):
        print("  全部一致")


if __name__ == "__main__":
    main()
