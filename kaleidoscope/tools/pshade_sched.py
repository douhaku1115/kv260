# -*- coding: utf-8 -*-
"""ピース描画の並び替え器を、クロック単位で模擬して実測する。

「1命令 = 1クロック = 1画素」で計算していたが、その前提を確かめていなかった。
数えていなかったものが3つある。

  1. 画素ごとのレジスタ初期値の書き込み (レジスタの書き込み口は1本)
  2. vq から q を作る回転 (掛け算4回)
  3. 枠の端数。1つの枠は LANES x WARP 画素ぶんあるが、ピースが小さいと余る
     ラメは1個112画素しかないので、枠が240画素だと半分以上が無駄になる

3 を避けるには「同じ種類の複数のピースの画素を1つの枠に詰める」必要がある。
そのために枠ごとに何個のピースを混ぜられるかを PSLOTS で変えて比べる。

  使い方:  python tools/pshade_sched.py
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kv_cell as K
import piece_table as PT
import piece_isa as ISA

CELL = 256            # セルの一辺
WARP = 24             # 1レーンが束ねる画素数 (書き戻しが 23 段目なので 24 以上)
PIX_CLK = 74.25e6
FPS = 60.0

# 毎画素レジスタへ書く値の数。種類ごとに違うので measure_preload() で数える。
#   画素ごとに変わるのは qx qy vqx vqy だけ。
#   seed / e / rot / time はピースごとに一定なので、レーンの中の
#   小さな「ピース定数バンク」(枠あたり4ピースぶん) に置く。毎画素は書かない。
#   z はどのプログラムも読まない (e と奥行きの暗さは外で作る)。
#   qx,qy は並び替え器が走査しながら足し算で作るので、回転の命令は要らない。
PER_PIXEL = ("qx", "qy", "vqx", "vqy")


def measure_preload():
    """種類ごとに、毎画素レジスタへ書く値の数を数える"""
    import pasm
    out = {}
    for key in KEYS:
        _, _, meta = pasm.assemble(key)
        used = set()
        for op, d, a, (bK, B), (cK, C) in meta:
            form = pasm.FORM[op]
            if form[0] == "r" and a < len(pasm.INPUTS): used.add(pasm.INPUTS[a])
            if bK == "r" and B < len(pasm.INPUTS): used.add(pasm.INPUTS[B])
            if cK == "r" and C < len(pasm.INPUTS): used.add(pasm.INPUTS[C])
        out[key] = sum(1 for n in PER_PIXEL if n in used)
    return out


KEYS = ["glass", "rod", "hexprism", "blob", "crescent", "bead", "stone", "glitter", "bubble"]


def bbox_pixels(p, n=CELL):
    """そのピースを描くのに走査する画素数 (セル n x n のとき)"""
    typ = int(p["type"])
    r = p["r"] * (0.85 + 0.3 * p["z"])
    pad = 2.6 if typ == K.GLITTER else 1.2
    half = r * pad
    x0 = max(int(math.floor((p["x"] - half + 1.0) * 0.5 * n)), 0)
    x1 = min(int(math.ceil((p["x"] + half + 1.0) * 0.5 * n)), n)
    y0 = max(int(math.floor((p["y"] - half + 1.0) * 0.5 * n)), 0)
    y1 = min(int(math.ceil((p["y"] + half + 1.0) * 0.5 * n)), n)
    return max(0, x1 - x0) * max(0, y1 - y0)


def schedule(parts, instr, pre, lanes, pslots):
    """枠に詰めて、総クロック数と無駄を返す。

    pslots = 1 個の枠に混ぜられるピースの数。1 なら混ぜない (端数が大きい)。
    枠には同じ種類のピースしか入れられない (プログラムが違うため)。
    """
    slots = lanes * WARP
    # 種類ごとにまとめる。同じ種類が並べば隣のピースと詰められる
    by_type = {}
    for p in parts:
        by_type.setdefault(int(p["type"]), []).append(p)

    clocks = 0
    used = 0
    total = 0
    groups = 0

    for typ, plist in by_type.items():
        key = [k for k, v in K.KEY_TO_TYPE.items() if v == typ][0]
        n_instr = instr[key] + pre[key]

        fill = 0          # いま詰めている枠の画素数
        npiece = 0        # いま詰めている枠に入っているピースの数
        for p in plist:
            px = bbox_pixels(p)
            total += px
            while px > 0:
                if npiece >= pslots or fill >= slots:
                    clocks += n_instr * WARP      # 枠を1つ流す
                    groups += 1
                    used += fill
                    fill, npiece = 0, 0
                take = min(px, slots - fill)
                fill += take
                px -= take
                npiece += 1
                if px > 0:
                    # まだ残っている = 枠がいっぱい。次の枠へ
                    clocks += n_instr * WARP
                    groups += 1
                    used += fill
                    fill, npiece = 0, 0
        if fill:
            clocks += n_instr * WARP
            groups += 1
            used += fill

    return clocks, used, total, groups


def main():
    import pasm
    pre = measure_preload()
    # 命令数はアセンブラの出力そのもの (ATLEN と SINCOS が 2 命令に割れた後の数)
    instr = {k: len(pasm.assemble(k)[0]) for k in KEYS}
    names = {p[0]: p[1] for p in PT.KV_PIECES}

    print("セル %dx%d、WARP %d、レーンあたり 1 枠 = %d 画素\n" % (CELL, CELL, WARP, WARP))
    print("  種類        命令  毎画素の初期値  合計")
    for k in KEYS:
        print("  %-9s %4d  %8d      %5d" % (names[k], instr[k], pre[k], instr[k] + pre[k]))

    frame = PIX_CLK / FPS
    for label, use_max in (("既定", False), ("上限", True)):
        rng = random.Random(1)
        parts = K.make_parts(rng, use_max)
        print("\n【%s %d 個】" % (label, len(parts)))
        print("  枠に混ぜる   レーン  総クロック   フレーム   無駄    実効Hz")
        for pslots in (1, 4, 16):
            for lanes in (8, 12, 16):
                cl, used, total, groups = schedule(parts, instr, pre, lanes, pslots)
                waste = 100.0 * (1.0 - used / float(groups * lanes * WARP))
                f = cl / frame
                hz = 60.0 / max(1, math.ceil(f))
                print("   %2d 個まで   %2d    %8.2f M   %5.2f 本   %4.1f%%   %4.1f Hz"
                      % (pslots, lanes, cl / 1e6, f, waste, hz))


if __name__ == "__main__":
    main()
