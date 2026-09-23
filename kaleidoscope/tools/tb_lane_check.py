# -*- coding: utf-8 -*-
"""レーンの RTL と Python の計算を突き合わせる。

  1. 画素 24 個ぶんの入力を作って simbuild/lane_in.hex に出す
  2. xsim で sim/tb_lane.v を回す (種類ごとに命令の範囲を渡す)
  3. 出てきた simbuild/lane_out.txt と Python の結果を比べる

固定小数点・CORDIC・表引きの誤差が、ここで初めて実数として出る。

  使い方:
    python tools/tb_lane_check.py            9 種すべて
    python tools/tb_lane_check.py stone      1 種だけ
"""
import math
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
WORK = os.path.join(ROOT, "simbuild")
sys.path.insert(0, HERE)

import pasm
import pasm_check as PC
import piece_isa as ISA
import kv_cell as K
import piece_table as PT

VIV = "E:/vivado/2025.2/Vivado/bin"
WARP = 24
ONE = float(1 << pasm.FRAC)


def fx24(v):
    n = int(round(float(v) * ONE))
    n = max(-(1 << 23), min((1 << 23) - 1, n))
    return n & 0xFFFFFF


def unfx(u):
    return (u - (1 << 24) if u & (1 << 23) else u) / ONE


def make_input(key):
    """画素 24 個を、その種類の枠の中からまんべんなく取る"""
    pad = 2.6 if key == "glitter" else 1.2
    rng = np.random.RandomState(7)
    vqx = rng.uniform(-pad, pad, WARP)
    vqy = rng.uniform(-pad, pad, WARP)
    seed, z, rot, t = 0.37, 0.7, 0.9, 3.3
    e = 0.1 + (0.025 - 0.1) * z
    ca, sa = math.cos(rot), math.sin(rot)
    env = dict(qx=ca * vqx - sa * vqy, qy=sa * vqx + ca * vqy, vqx=vqx, vqy=vqy,
               seed=np.full(WARP, seed), z=np.full(WARP, z),
               e=np.full(WARP, e), rot=np.full(WARP, rot), time=np.full(WARP, t))
    return env


def write_input(env):
    path = os.path.join(WORK, "lane_in.hex")
    with open(path, "w") as f:
        for nm in pasm.INPUTS:
            for i in range(WARP):
                f.write("%06x\n" % fx24(env[nm][i]))


def build():
    os.makedirs(WORK, exist_ok=True)
    for h in ("pprog.hex", "pprog_base.hex", "log2_lut.hex", "exp2_lut.hex", "atan_lut.hex"):
        src = os.path.join(ROOT, "rtl", h)
        with open(src) as a, open(os.path.join(WORK, h), "w") as b:
            b.write(a.read())
    cmd = [os.path.join(VIV, "xvlog.bat"), "-i", os.path.join(ROOT, "rtl"),
           os.path.join(ROOT, "rtl", "pcordic.v"),
           os.path.join(ROOT, "rtl", "ptrans.v"),
           os.path.join(ROOT, "rtl", "pshade_lane.v"),
           os.path.join(ROOT, "sim", "tb_lane.v")]
    r = subprocess.run(cmd, cwd=WORK, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode:
        print(r.stdout[-3000:], r.stderr[-2000:])
        sys.exit(1)
    r = subprocess.run([os.path.join(VIV, "xelab.bat"), "-debug", "off",
                        "-timescale", "1ns/1ps", "tb_lane", "-s", "snap_lane"],
                       cwd=WORK, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode:
        print(r.stdout[-3000:], r.stderr[-2000:])
        sys.exit(1)


def run_sim(start, length):
    # 流す範囲はファイルで渡す (プラス引数は Windows のバッチで壊れる)
    with open(os.path.join(WORK, "lane_range.hex"), "w") as f:
        f.write("%04x\n%04x\n" % (start, length))
    out_path = os.path.join(WORK, "lane_out.txt")
    if os.path.exists(out_path):
        os.remove(out_path)
    r = subprocess.run([os.path.join(VIV, "xsim.bat"), "snap_lane", "-runall"],
                       cwd=WORK, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if not os.path.exists(out_path):
        print((r.stdout or "")[-3000:])
        sys.exit(1)
    out = []
    with open(os.path.join(WORK, "lane_out.txt")) as f:
        for ln in f:
            a, k, w = ln.split()
            out.append((unfx(int(a, 16)), unfx(int(k, 16)), unfx(int(w, 16))))
    return out


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None
    order = ["crescent", "rod", "bubble", "bead", "blob", "hexprism",
             "glass", "glitter", "stone"]
    if only:
        order = [only]
    names = {p[0]: p[1] for p in PT.KV_PIECES}

    # 種類ごとの開始番地と長さ
    base, lens = {}, {}
    pos = 0
    for k in ["bead", "glass", "glitter", "hexprism", "bubble",
              "stone", "rod", "blob", "crescent"]:
        w, _, _ = pasm.assemble(k)
        base[k], lens[k] = pos, len(w)
        pos += len(w)

    build()
    print("  種類        命令   Aの差     Kの差     Wの差    色にすると")
    for key in order:
        env = make_input(key)
        write_input(env)
        got = run_sim(base[key], lens[key])

        words, _, _ = pasm.assemble(key)
        A, Kk, Ww = PC.run_encoded(words, {n: v.copy() for n, v in env.items()})

        g = np.array(got)
        dA = np.abs(g[:, 0] - A).max()
        dK = np.abs(g[:, 1] - Kk).max()
        dW = np.abs(g[:, 2] - Ww).max()
        # 色に直すとどれだけか。色を 0.6 として (c*K + W) の差を 255 階調で
        dcol = (0.6 * dK + dW) * 255.0
        print("  %-9s %4d   %.2e  %.2e  %.2e   %5.2f / 255"
              % (names[key], lens[key], dA, dK, dW, dcol))


if __name__ == "__main__":
    main()
