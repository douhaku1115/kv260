# -*- coding: utf-8 -*-
"""アセンブラの出力を、名前のままのプログラムと突き合わせる。

確かめたいのは主に2つ。
  ・レジスタの使い回し（32本に収めるため、死んだ名前の場所を再利用している）で
    まだ使う値を壊していないか
  ・64bit への詰め方（即値かレジスタかの取り違え）が正しいか

rtl/pprog.hex を読み、番号だけの命令として実行して、
`tools/piece_isa.py` の名前つきプログラムと同じ A / K / W が出るかを見る。

  使い方:  python tools/pasm_check.py
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pasm
import piece_isa as ISA
import kv_cell as K

FRAC = pasm.FRAC
ONE = float(1 << FRAC)

INV_OPS = {v: k for k, v in pasm.OPS.items()}


def unfx(u):
    """S6.17 の 24bit → 浮動小数点"""
    return (u - (1 << 24) if u & (1 << 23) else u) / ONE


def decode(w):
    op = INV_OPS[(w >> 58) & 0x3F]
    d = (w >> 53) & 0x1F
    a = (w >> 48) & 0x1F
    B = (w >> 24) & 0xFFFFFF
    C = w & 0xFFFFFF
    return op, d, a, B, C


def meta_words(meta):
    """meta から words と同じ長さの並びを作る (中身は run_encoded が exact を見る)"""
    return list(range(len(meta)))


def run_encoded(words, env, exact=None):
    """番号だけの命令列を実行する。演算の中身は piece_isa と同じ。

    exact を渡すと、即値を S6.17 に丸める前の値で回す。
    丸めの影響だけを切り分けるため。
    """
    r = [np.zeros_like(env["qx"]) for _ in range(pasm.NREG)]
    for i, nm in enumerate(pasm.INPUTS):
        r[i] = env[nm]

    for idx, w in enumerate(words):
        if exact is None:
            op, d, a, B, C = decode(w)
            bK = cK = None
        else:
            op, d, a, (bK, B), (cK, C) = exact[idx]
        form = pasm.FORM[op]
        va = r[a]

        def imm(kind, val):
            """即値。exact のときは丸める前の値をそのまま使う"""
            return val if kind == "i" else unfx(val)

        vb = r[B] if form[1] == "r" else (B if bK == "i" else unfx(B))
        vc = r[C] if form[2] == "r" else (C if cK == "i" else unfx(C))
        iB = B if bK == "i" else unfx(B)
        iC = C if cK == "i" else unfx(C)

        if   op == "MOV":    r[d] = va
        elif op == "LDI":    r[d] = np.full_like(va, iB)
        elif op == "ADD":    r[d] = va + vb
        elif op == "SUB":    r[d] = va - vb
        elif op == "MUL":    r[d] = va * vb
        elif op == "MADD":   r[d] = va * vb + vc
        elif op == "ADDI":   r[d] = va + iB
        elif op == "MULI":   r[d] = va * iB
        elif op == "MADDI":  r[d] = va * iB + iC
        elif op == "MADDC":  r[d] = va * iB + vc
        elif op == "MIN":    r[d] = np.minimum(va, vb)
        elif op == "MAX":    r[d] = np.maximum(va, vb)
        elif op == "MINI":   r[d] = np.minimum(va, iB)
        elif op == "MAXI":   r[d] = np.maximum(va, iB)
        elif op == "ABS":    r[d] = np.abs(va)
        elif op == "NEG":    r[d] = -va
        elif op == "FLOOR":  r[d] = np.floor(va)
        elif op == "CLAMP":  r[d] = np.clip(va, iB, iC)
        elif op == "LEN":    r[d] = np.hypot(va, vb)
        elif op == "ATAN":   r[d] = np.arctan2(vb, va)
        elif op == "SIN":    r[d] = np.sin(va)
        elif op == "COS":    r[d] = np.cos(va)
        elif op == "RECIP":  r[d] = 1.0 / np.where(np.abs(va) < 1e-9, 1e-9, va)
        elif op == "SQRT":   r[d] = np.sqrt(np.maximum(va, 0.0))
        elif op == "POW":    r[d] = np.power(np.maximum(va, 0.0), iB)
        elif op == "EXPN":   r[d] = np.exp(-va)
        elif op == "SSTEP":  r[d] = ISA._ss(va, vb, vc)
        elif op == "SSTEPI": r[d] = ISA._ss(va, iB, iC)
        else: raise ValueError(op)

    return (r[pasm.OUTREG["A"]], r[pasm.OUTREG["K"]], r[pasm.OUTREG["W"]])


def main():
    order = ["glass", "rod", "hexprism", "blob", "crescent", "bead", "stone", "glitter", "bubble"]
    names = {p[0]: p[1] for p in __import__("piece_table").KV_PIECES}
    n = 120
    print("  種類        命令   丸めあり    丸めなし")
    bad = 0
    for key in order:
        pad = 2.6 if key == "glitter" else 1.2
        g = np.linspace(-pad, pad, n)
        vqx, vqy = np.meshgrid(g, g)
        seed, z, rot, t = 0.37, 0.7, 0.9, 3.3
        e = 0.1 + (0.025 - 0.1) * z
        ca, sa = math.cos(rot), math.sin(rot)
        env = dict(qx=ca * vqx - sa * vqy, qy=sa * vqx + ca * vqy,
                   vqx=vqx, vqy=vqy,
                   seed=np.full_like(vqx, seed), z=np.full_like(vqx, z),
                   e=np.full_like(vqx, e), rot=np.full_like(vqx, rot),
                   time=np.full_like(vqx, t))

        words, _, meta = pasm.assemble(key)
        A2, K2, W2 = run_encoded(words, dict(env))
        # 即値を丸めずに同じ命令列を回す。これが一致すれば
        # レジスタの使い回しと 64bit への詰め方は正しく、差は丸めだけと分かる
        A3, K3, W3 = run_encoded(meta_words(meta), dict(env), exact=meta)

        c = ISA.Core(dict(env)).run(ISA.program(key))
        d_q = max(np.abs(A2 - c.out["A"]).max(), np.abs(K2 - c.out["K"]).max(),
                  np.abs(W2 - c.out["W"]).max())
        d_x = max(np.abs(A3 - c.out["A"]).max(), np.abs(K3 - c.out["K"]).max(),
                  np.abs(W3 - c.out["W"]).max())
        if d_x > 1e-9:
            bad += 1
        print("  %-9s %4d   %.3e   %.3e" % (names[key], len(words), d_q, d_x))

    print("\n  即値を丸めないときに一致すれば、レジスタの使い回しと詰め方は正しい")
    print("  %s" % ("→ 9 種すべて一致した" if bad == 0 else "★ %d 種が不一致" % bad))


if __name__ == "__main__":
    main()
