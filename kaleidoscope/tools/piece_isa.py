# -*- coding: utf-8 -*-
"""ピース描画の命令セットと、9種ぶんのマイクロコード。

段5c の演算器は「種類ごとのプログラムを1命令ずつ実行する」作りにする。
種類を足すのは AXI でプログラムを書くだけで済み、再合成が要らない。

ここでは命令セットを Python で実装し、9種を実際に書き下して
  ・`tools/kv_cell.py`（正解）と同じ絵になるか
  ・1画素あたり何命令かかるか
  ・どの演算器（CORDIC / 表 / 除算 / 平方根）を何回使うか
を測る。演算器の数と描き直し間隔はこの数字で決まる。

【色の扱い】
  プログラムは色そのものを扱わない。3つの値だけを出す。
      A = 不透明度
      K = 粒の色に掛ける係数
      W = 白を足す量
  最終色 = (粒の色 * K + W) * 奥行きの暗さ
  こうすると RGB 3本ぶんの演算がプログラムから消え、最後に1回で済む。
  9種すべてがこの形に収まることを確かめてある。

  使い方:  python tools/piece_isa.py
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kv_cell as K
import ref_cell as R

LX, LY, LZ = R.L
PI = math.pi
PI2 = 2.0 * math.pi

# 命令がどの演算器を使うか。面積の見積もりに使う
UNIT = {
    "LEN": "cordic", "ATLEN": "cordic", "SIN": "cordic", "COS": "cordic", "SINCOS": "cordic",
    "SSTEP": "lut", "SSTEPI": "lut", "POW": "lut", "EXPN": "lut",
    "RECIP": "div", "SQRT": "sqrt",
}


def _ss(x, a, b):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


class Core:
    """1画素ぶんのプログラムを実行する。配列でまとめて回すので絵がそのまま出る"""

    def __init__(self, env):
        self.r = dict(env)
        self.out = {}
        self.n = 0
        self.units = {}

    def _v(self, x):
        return self.r[x] if isinstance(x, str) and x in self.r else float(x)

    def run(self, prog):
        for line in prog:
            line = line.split("#")[0].strip()
            if not line:
                continue
            op, _, rest = line.partition(" ")
            op = op.upper()
            f = [s.strip() for s in rest.split(",")] if rest.strip() else []
            self.n += 1
            u = UNIT.get(op)
            if u:
                self.units[u] = self.units.get(u, 0) + 1
            self.exec1(op, f)
        return self

    def exec1(self, op, f):
        r, v = self.r, self._v
        if   op == "LDI":    r[f[0]] = np.full_like(r["qx"], float(f[1]))
        elif op == "MOV":    r[f[0]] = v(f[1]) * np.ones_like(r["qx"])
        elif op == "ADD":    r[f[0]] = v(f[1]) + v(f[2])
        elif op == "SUB":    r[f[0]] = v(f[1]) - v(f[2])
        elif op == "MUL":    r[f[0]] = v(f[1]) * v(f[2])
        elif op == "MADD":   r[f[0]] = v(f[1]) * v(f[2]) + v(f[3])
        elif op == "ADDI":   r[f[0]] = v(f[1]) + float(f[2])
        elif op == "MULI":   r[f[0]] = v(f[1]) * float(f[2])
        elif op == "MADDI":  r[f[0]] = v(f[1]) * float(f[2]) + float(f[3])
        elif op == "MADDC":  r[f[0]] = v(f[1]) * float(f[2]) + v(f[3])
        elif op == "MIN":    r[f[0]] = np.minimum(v(f[1]), v(f[2]))
        elif op == "MAX":    r[f[0]] = np.maximum(v(f[1]), v(f[2]))
        elif op == "MINI":   r[f[0]] = np.minimum(v(f[1]), float(f[2]))
        elif op == "MAXI":   r[f[0]] = np.maximum(v(f[1]), float(f[2]))
        elif op == "ABS":    r[f[0]] = np.abs(v(f[1]))
        elif op == "NEG":    r[f[0]] = -v(f[1])
        elif op == "FLOOR":  r[f[0]] = np.floor(v(f[1]))
        elif op == "CLAMP":  r[f[0]] = np.clip(v(f[1]), float(f[2]), float(f[3]))
        elif op == "SSTEP":  r[f[0]] = _ss(v(f[1]), v(f[2]), v(f[3]))
        elif op == "SSTEPI": r[f[0]] = _ss(v(f[1]), float(f[2]), float(f[3]))
        elif op == "LEN":    r[f[0]] = np.hypot(v(f[1]), v(f[2]))
        elif op == "ATLEN":
            r[f[0]] = np.arctan2(v(f[3]), v(f[2]))       # 角
            r[f[1]] = np.hypot(v(f[2]), v(f[3]))         # 長さ (CORDIC 1回で両方出る)
        elif op == "SIN":    r[f[0]] = np.sin(v(f[1]))
        elif op == "COS":    r[f[0]] = np.cos(v(f[1]))
        elif op == "SINCOS":
            r[f[0]] = np.sin(v(f[2]))
            r[f[1]] = np.cos(v(f[2]))
        elif op == "POW":    r[f[0]] = np.power(np.maximum(v(f[1]), 0.0), float(f[2]))
        elif op == "EXPN":   r[f[0]] = np.exp(-v(f[1]))
        elif op == "SQRT":   r[f[0]] = np.sqrt(np.maximum(v(f[1]), 0.0))
        elif op == "RECIP":  r[f[0]] = 1.0 / np.where(np.abs(v(f[1])) < 1e-9, 1e-9, v(f[1]))
        elif op in ("OUTA", "OUTK", "OUTW"):
            self.out[op[-1]] = v(f[0])
            self.n -= 1                                  # 出力は演算ではないので数えない
        else:
            raise ValueError("知らない命令 %s" % op)


# ============================================================
#  9種のプログラム
#   使える入力: qx qy vqx vqy seed z e rot time
#   e は 0.1→0.025 (奥ほどぼける)。呼ぶ側が渡す
# ============================================================

PROGS = {}

PROGS["bead"] = """
LEN    d, vqx, vqy
MADDI  lo, e, -1, 1
MADDI  hi, e,  1, 1
SSTEP  s, d, lo, hi
MADDI  A, s, -1, 1
MAXI   den, d, 1
RECIP  inv, den
MUL    nx, vqx, inv
MUL    ny, vqy, inv
MUL    nn, nx, nx
MADD   nn, ny, ny, nn
MADDI  nn, nn, -1, 1
SQRT   nz, nn
MULI   dif, nx, %(LX)r
MADDC  dif, ny, %(LY)r, dif
MADDC  dif, nz, %(LZ)r, dif
MAXI   dif, dif, 0
MUL    rz, dif, nz
MADDI  rz, rz, 2, %(NLZ)r
MAXI   rz, rz, 0
POW    sp, rz, 40
MULI   th, nx, %(NLX)r
MADDC  th, ny, %(NLY)r, th
SSTEPI th, th, -0.2, 0.9
LDI    Kc, 0.3
MADDC  Kc, dif, 0.55, Kc
MADDC  Kc, th, 0.7, Kc
MULI   Wc, sp, 1.3
OUTA   A
OUTK   Kc
OUTW   Wc
"""

PROGS["glass"] = """
MADDI  sx, seed, 0.45, 1
MUL    px, qx, sx
MADDI  sy, seed, -0.20, 1
MUL    py, qy, sy
MULI   nn, seed, 2.999
FLOOR  nn, nn
ADDI   nn, nn, 3
ATLEN  an, pl, px, py
MULI   k, nn, %(INV_PI2)r
MUL    sgm, an, k
ADDI   sgm, sgm, 0.5
FLOOR  sgm, sgm
RECIP  invn, nn
MULI   bw, invn, %(PI2)r
MUL    sgm, sgm, bw
SUB    dd, an, sgm
COS    dd, dd
MUL    v, dd, pl
MADDI  lo, e, -1, 0.72
MADDI  hi, e,  1, 0.72
SSTEP  s, v, lo, hi
MADDI  A, s, -1, 1
SSTEPI edge, v, 0.54, 0.72
ADDI   pl2, pl, 0.0001
RECIP  ipl, pl2
MUL    ux, px, ipl
MUL    uy, py, ipl
MULI   face, ux, %(NLX)r
MADDC  face, uy, %(NLY)r, face
MULI   mn, pl2, 1.3888889
MINI   mn, mn, 1
MUL    face, face, mn
MADDI  face, face, 0.5, 0.5
MADDI  Kc, face, 0.6, 0.8
MULI   Wc, edge, 0.35
MADDI  am, edge, 0.25, 0.72
MUL    A, A, am
OUTA   A
OUTK   Kc
OUTW   Wc
"""

PROGS["glitter"] = """
ATLEN  an, l6, qx, qy
MULI   sgm, an, %(INV_B6)r
ADDI   sgm, sgm, 0.5
FLOOR  sgm, sgm
MULI   sgm, sgm, %(B6)r
SUB    dd, an, sgm
COS    dd, dd
MUL    v, dd, l6
MULI   e2, e, 2
MADDI  lo, e2, -1, 0.85
MADDI  hi, e2,  1, 0.85
SSTEP  s, v, lo, hi
MADDI  cov, s, -1, 1
MULI   ph, rot, 4
MADDC  ph, seed, 60, ph
MADDI  sr, seed, 0.6, 0.3
MUL    tt, sr, time
ADD    ph, ph, tt
SIN    ph, ph
MADDI  ph, ph, 0.5, 0.5
POW    sp, ph, 14
LEN    lq, vqx, vqy
MULI   g1, lq, 1.5
EXPN   g1, g1
MUL    glow, sp, g1
MULI   glow, glow, 0.9
ABS    fx, vqx
MULI   fx, fx, 12
EXPN   fx, fx
ABS    fy, vqy
MULI   fy, fy, 12
EXPN   fy, fy
ADD    fl, fx, fy
MULI   g2, lq, 0.9
EXPN   g2, g2
MUL    fl, fl, g2
MUL    fl, fl, sp
MULI   fl, fl, 0.6
ADD    gf, glow, fl
MULI   Kc, cov, 0.65
MADDC  Kc, gf, 0.5, Kc
MUL    Wc, sp, cov
MULI   Wc, Wc, 1.4
MADDC  Wc, gf, 0.5, Wc
MULI   A, cov, 0.9
ADD    A, A, gf
CLAMP  A, A, 0, 1
OUTA   A
OUTK   Kc
OUTW   Wc
"""

PROGS["hexprism"] = """
ABS    ax, qx
ADDI   ax, ax, -0.9
ABS    ay, qy
ADDI   ay, ay, -0.3
MAX    d, ax, ay
NEG    ne, e
SSTEP  s, d, ne, e
MADDI  A, s, -1, 1
MULI   t, qy, 3.3333333
CLAMP  t, t, -1, 1
MADDI  bd, t, 1.5, 1.5
FLOOR  bd, bd
CLAMP  bd, bd, 0, 2
ADDI   bd, bd, -1
MULI   th, bd, %(PI3)r
MADDC  th, seed, %(PI3)r, th
SINCOS sn, cs, th
MULI   dif, sn, %(LY)r
MADDC  dif, cs, %(LZ)r, dif
MAXI   dif, dif, 0
POW    spc, dif, 12
LDI    sh, 0.2
MADDC  sh, dif, 0.8, sh
MADDC  sh, spc, 0.75, sh
ABS    at, t
ADDI   at, at, -0.3333333
ABS    at, at
SSTEPI eg, at, 0, 0.05
MADDI  eg, eg, -1, 1
ABS    cx, qx
SSTEPI cp, cx, 0.86, 0.9
MADDI  Kc, sh, 0.9, 0.55
MULI   Wc, eg, 0.30
MADDC  Wc, cp, 0.20, Wc
MULI   A, A, 0.90
OUTA   A
OUTK   Kc
OUTW   Wc
"""

PROGS["blob"] = """
ATLEN  an, lq, qx, qy
MULI   a3, an, 3
MADDC  a3, seed, 17, a3
SIN    a3, a3
MULI   a5, an, 5
MADDC  a5, seed, 29, a5
SIN    a5, a5
LDI    rad, 0.82
MADDC  rad, a3, 0.1, rad
MADDC  rad, a5, 0.06, rad
RECIP  ir, rad
MUL    d, lq, ir
MADDI  lo, e, -1, 1
MADDI  hi, e,  1, 1
SSTEP  s, d, lo, hi
MADDI  A, s, -1, 1
MUL    cr, d, d
MADDI  cr, cr, -1, 1
CLAMP  cr, cr, 0, 1
ADDI   hx, vqx, 0.3
ADDI   hy, vqy, -0.35
LEN    hd, hx, hy
MULI   hd, hd, 6
EXPN   hl, hd
MULI   Wc, hl, 0.4
MADDI  Kc, cr, 0.8, 0.7
MADDI  am, cr, 0.4, 0.55
MUL    A, A, am
OUTA   A
OUTK   Kc
OUTW   Wc
"""

PROGS["crescent"] = """
LEN    l1, qx, qy
ADDI   d1, l1, -0.9
ADDI   cx, qx, -0.42
ADDI   cy, qy, -0.18
LEN    l2, cx, cy
ADDI   d2, l2, -0.74
NEG    d2, d2
MAX    d, d1, d2
NEG    ne, e
SSTEP  s, d, ne, e
MADDI  A, s, -1, 1
MULI   g, d, -4.5454545
CLAMP  g, g, 0, 1
MADDI  Kc, g, 0.5, 0.7
LDI    Wc, 0
MULI   A, A, 0.95
OUTA   A
OUTK   Kc
OUTW   Wc
"""

PROGS["bead"] = PROGS["bead"]

PROGS["stone"] = """
ATLEN  an, lq, qx, qy
MULI   a3, an, 3
MADDC  a3, seed, 20, a3
SIN    a3, a3
MULI   a5, an, 5
MADDC  a5, seed, 37, a5
SIN    a5, a5
LDI    rad, 0.84
MADDC  rad, a3, 0.08, rad
MADDC  rad, a5, 0.05, rad
RECIP  ir, rad
MUL    d, lq, ir
MADDI  lo, e, -1, 1
MADDI  hi, e,  1, 1
SSTEP  s, d, lo, hi
MADDI  A, s, -1, 1
MUL    nx, vqx, ir
MUL    ny, vqy, ir
MUL    l2, nx, nx
MADD   l2, ny, ny, l2
MAXI   l2m, l2, 1
SQRT   l2m, l2m
RECIP  sc, l2m
MUL    nx, nx, sc
MUL    ny, ny, sc
MUL    nn, nx, nx
MADD   nn, ny, ny, nn
MADDI  nn, nn, -1, 1
SQRT   nz, nn
MULI   dif, nx, %(LX)r
MADDC  dif, ny, %(LY)r, dif
MADDC  dif, nz, %(LZ)r, dif
MAXI   dif, dif, 0
MULI   s6, seed, 6
SINCOS ss, cc, s6
MUL    b1, qx, cc
MADD   b1, qy, ss, b1
MULI   b1, b1, 9
MULI   p1, qx, 4
MADDC  p1, seed, 11, p1
SIN    p1, p1
MULI   p2, qy, 5
MADDC  p2, seed, -7, p2
SIN    p2, p2
MUL    p1, p1, p2
MADDC  b1, p1, 2.5, b1
MADDC  b1, seed, 30, b1
SIN    bnd, b1
SSTEPI m, bnd, -0.3, 0.9
MADDI  k1, m, 0.1, 0.55
MADDI  k2, dif, 0.8, 0.4
MUL    Kc, k1, k2
MULI   Wc, m, 0.35
MUL    Wc, Wc, k2
MUL    rz, dif, nz
MADDI  rz, rz, 2, %(NLZ)r
MAXI   rz, rz, 0
POW    spc, rz, 24
MADDC  Wc, spc, 0.5, Wc
OUTA   A
OUTK   Kc
OUTW   Wc
"""

PROGS["rod"] = """
ABS    ax, qx
ADDI   ax, ax, -0.6
MAXI   ax, ax, 0
LEN    d, ax, qy
ADDI   d, d, -0.3
MULI   lo, e, -0.4
MULI   hi, e,  0.4
SSTEP  s, d, lo, hi
MADDI  A, s, -1, 1
MULI   cy, qy, 3.3333333
CLAMP  cy, cy, -1, 1
MUL    c2, cy, cy
MADDI  c2, c2, -1, 1
SQRT   sh, c2
ADDI   hh, cy, 0.4
ABS    hh, hh
MULI   hh, hh, 2.5
MADDI  hh, hh, -1, 1
MAXI   hh, hh, 0
POW    hl, hh, 3
MADDI  Kc, sh, 0.7, 0.55
MULI   Wc, hl, 0.8
MULI   A, A, 0.95
OUTA   A
OUTK   Kc
OUTW   Wc
"""

PROGS["bubble"] = """
LEN    d, vqx, vqy
SSTEPI rg, d, 0.7, 0.97
MADDI  hi, e, 1, 1.03
LDI    lo97, 0.97
SSTEP  s2, d, lo97, hi
MADDI  s2, s2, -1, 1
MUL    rg, rg, s2
ADDI   sx, vqx, 0.38
ADDI   sy, vqy, -0.4
LEN    sd, sx, sy
MULI   sd, sd, 9
EXPN   sp, sd
MULI   A, rg, 0.5
MADDC  A, sp, 0.9, A
CLAMP  A, A, 0, 1
MULI   Kc, rg, 0.6
MADDC  Kc, sp, 1.2, Kc
LDI    Wc, 0
OUTA   A
OUTK   Kc
OUTW   Wc
"""

SUBST = dict(LX=float(LX), LY=float(LY), LZ=float(LZ),
             NLX=float(-LX), NLY=float(-LY), NLZ=float(-LZ),
             PI2=PI2, INV_PI2=1.0 / PI2, PI3=PI / 3.0,
             B6=PI2 / 6.0, INV_B6=6.0 / PI2)


def program(key):
    return (PROGS[key] % SUBST).strip().split("\n")


# ============================================================
#  正解 (tools/kv_cell.py) と突き合わせる
# ============================================================

def check(key, n=200):
    """key の種類を格子いっぱいに描いて、プログラムと正解の差を測る"""
    typ = K.KEY_TO_TYPE[key]
    pad = 2.6 if key == "glitter" else 1.2
    g = np.linspace(-pad, pad, n)
    vqx, vqy = np.meshgrid(g, g)
    seed, z, rot, t = 0.37, 0.7, 0.9, 3.3
    e = 0.1 + (0.025 - 0.1) * z
    ca, sa = math.cos(rot), math.sin(rot)
    qx = ca * vqx - sa * vqy
    qy = sa * vqx + ca * vqy

    # ---- 正解 ----
    # 粒の色は何でもよい (K と W が解ければ一致する)。ただし気泡だけは
    # 参照実装が色を無視して (0.9,0.95,1.0) 固定で塗るので、その色を持たせる。
    # → ピースの表では気泡の色を #e6f2ff にしておくこと。
    col = np.array([0.9, 0.95, 1.0]) if key == "bubble" else np.array([0.37, 0.61, 0.83])
    p = {"type": typ, "key": key, "seed": seed, "z": z, "rot": rot, "col": col}
    rgb_ref, a_ref = K.shade_piece(p, qx, qy, vqx, vqy, t)
    depth = 0.65 + 0.35 * z

    # ---- プログラム ----
    env = dict(qx=qx, qy=qy, vqx=vqx, vqy=vqy,
               seed=np.full_like(qx, seed), z=np.full_like(qx, z),
               e=np.full_like(qx, e), rot=np.full_like(qx, rot),
               time=np.full_like(qx, t))
    c = Core(env).run(program(key))
    rgb_isa = (col * c.out["K"][..., None] + c.out["W"][..., None]) * depth
    # 気泡は「α を掛けた後の色」をそのまま出す (ラメと同じ扱い)。
    # 参照実装は tint*X / max(a,1e-3) と書いているが、合成のときに α を
    # 掛け直すのでほぼ打ち消し合う。割り算を残すと 1/0.001 = 1000 になり
    # S6.17 (±64) をあふれるので、割らずに出して合成側で掛けない。
    if key == "bubble":
        rgb_ref = rgb_ref * a_ref[..., None]

    da = np.abs(c.out["A"] - a_ref).max()
    dc = np.abs(rgb_isa - rgb_ref).max()
    return c.n, c.units, da, dc


def main():
    order = ["glass", "rod", "hexprism", "blob", "crescent", "bead", "stone", "glitter", "bubble"]
    names = {p[0]: p[1] for p in __import__("piece_table").KV_PIECES}

    print("種類ごとの命令数と、正解との差\n")
    print("  種類        命令  CORDIC  表  除算  平方根   Aの差    色の差")
    worst = 0
    for key in order:
        n, u, da, dc = check(key)
        worst = max(worst, n)
        print("  %-9s %4d  %5d %4d %4d %5d   %.5f  %.5f"
              % (names[key], n, u.get("cordic", 0), u.get("lut", 0),
                 u.get("div", 0), u.get("sqrt", 0), da, dc))
    print("\n  一番重い種類: %d 命令" % worst)

    # ---- セル1枚を描くのに要るクロックを、種類ごとの重さで積算する ----
    #   「一番重い 59 命令が全画素にかかる」と数えると過大になる。
    #   三日月は 16、棒は 23 で、重い天然石は既定で6個しかない。
    import piece_table as PT
    instr = {k: check(k, n=40)[0] for k in order}

    def total_clocks(idx):
        return sum(PT.area_px(p[0], p[3], p[4], p[idx]) * instr[p[0]] for p in PT.KV_PIECES)

    cl_def, cl_max = total_clocks(7), total_clocks(2)
    frame = PT.PIX_CLK / PT.FPS
    print("\n  セル1枚を描くのに要るクロック (面積 x 命令数)")
    print("    既定 %3d 個  %10.2f M   フレーム %.2f 本ぶん"
          % (sum(p[7] for p in PT.KV_PIECES), cl_def / 1e6, cl_def / frame))
    print("    上限 %3d 個  %10.2f M   フレーム %.2f 本ぶん"
          % (sum(p[2] for p in PT.KV_PIECES), cl_max / 1e6, cl_max / frame))

    print("\n  演算器の数ごとの、セルの描き直しの速さ")
    print("    演算器    既定 271 個        上限 625 個")
    for cores in (2, 4, 8, 12, 16):
        def hz(cl):
            f = cl / (frame * cores)
            return 60.0 / max(1.0, math.ceil(f))
        print("     %2d 個    %5.1f Hz (%.2f本)   %5.1f Hz (%.2f本)"
              % (cores, hz(cl_def), cl_def / (frame * cores),
                 hz(cl_max), cl_max / (frame * cores)))


if __name__ == "__main__":
    main()
