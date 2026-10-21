# -*- coding: utf-8 -*-
"""PS が毎フレーム書くピースの表の「元の値」を C に書き出す。段5d-7。

  vitis_src/parts_data.c / parts_data.h

中身は 2 つ。
  parts[]        ピースごとの元の値 (種類・位置・大きさ・回転・種・色)。
                 PS はこれから 24 語を計算して PL の表へ書く (main.c の PieceWords)。
                 並びは rtl/pparts.hex と同じ (gen_pparts.py の main と同じ乱数・並べ方)
  parts_check[]  rtl/pparts.hex そのもの。起動時に PS の計算と突き合わせる自己検査用
                 (PC に C コンパイラが無いので、C の計算はここでしか確かめられない)
  kind_orig[]    配色エディタの種類 (KINDS の順) ごとの元の色 (kv_cell.COLORS)。
                 main.c の配色「ORIGINAL」になる。ビーズと小ビーズは pprog の番号が同じ (0) なので、
                 色を分けるために parts[] に kind (KINDS の番号) を持たせる

  使い方:  python tools/gen_parts_c.py
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)

import kv_cell as K
import gen_pparts as GP

# 配色エディタの種類の並び。main.c の kind_name[] と同じ順。気泡は色を変えないので最後
KINDS = ["bead", "bead_s", "glass", "glitter", "stone", "hexprism", "rod", "blob", "crescent", "bubble"]
NCOL = 8          # 1 種類あたりの色の数 (main.c の KCOLS)


def main():
    rng = random.Random(3)
    parts = K.make_parts(rng, False)
    rng.shuffle(parts)
    sel = [p for p in parts if GP.piece_words(p)]
    sel = GP.order_by_type_then_z(sel)

    # pparts.hex と同じ並びになっているかを先に確かめる
    words = [v & 0xFFFFFF for p in sel for v in GP.piece_words(p)]
    hexw = [int(l, 16) for l in open(os.path.join(ROOT, "rtl", "pparts.hex")) if l.strip()]
    if words != hexw:
        print("★ pparts.hex と並びが違う。gen_pparts.py を先に回すこと")
        sys.exit(1)

    n = len(sel)
    out_c = os.path.join(ROOT, "vitis_src", "parts_data.c")
    out_h = os.path.join(ROOT, "vitis_src", "parts_data.h")
    with open(out_h, "w", encoding="utf-8", newline="\n") as f:
        f.write("/* tools/gen_parts_c.py が作る。手で直さない */\n")
        f.write("#ifndef PARTS_DATA_H\n#define PARTS_DATA_H\n\n")
        f.write("#define NPARTS %d\n" % n)
        f.write("#define NKINDS %d       /* 配色エディタの種類の数 (最後の気泡を含む) */\n" % len(KINDS))
        f.write("#define KCOLS  %d       /* 1 種類あたりの色の数 */\n\n" % NCOL)
        f.write("typedef struct {\n"
                "    unsigned char typ;      /* 種類 (pprog の番号) */\n"
                "    unsigned char kind;     /* 配色エディタの種類 (gen_parts_c.py の KINDS の番号) */\n"
                "    unsigned char glitter;  /* ラメ (枠を広く取る pad=2.6) */\n"
                "    unsigned char premul;   /* ラメ・気泡は色がプリマルチプライド */\n"
                "    unsigned char col[3];   /* 色 0〜255 */\n"
                "    double x, y, z, r, rot, seed;\n"
                "} Part;\n\n")
        f.write("extern const Part parts[NPARTS];\n")
        f.write("extern const unsigned int parts_check[NPARTS * 24];\n")
        f.write("/* 種類ごとの元の色 {R, G, B, 割合}。割合 0 の色は使わない */\n")
        f.write("extern const unsigned char kind_orig[NKINDS][KCOLS][4];\n\n#endif\n")
    with open(out_c, "w", encoding="utf-8", newline="\n") as f:
        f.write("/* tools/gen_parts_c.py が作る。手で直さない。\n"
                " * 並びは rtl/pparts.hex と同じ (種類ごと、種類の中は z 順)。 */\n")
        f.write('#include "parts_data.h"\n\n')
        f.write("const Part parts[NPARTS] = {\n")
        for p in sel:
            key = p["key"]
            col = [int(c * 255 + .5) for c in p["col"]]
            f.write("  {%d, %d, %d, %d, {%d, %d, %d}, %.17g, %.17g, %.17g, %.17g, %.17g, %.17g},\n"
                    % (K.KEY_TO_TYPE[key], KINDS.index(key), 1 if key == "glitter" else 0,
                       1 if key in ("glitter", "bubble") else 0,
                       col[0], col[1], col[2],
                       p["x"], p["y"], p["z"], p["r"], p["rot"], p["seed"]))
        f.write("};\n\n")
        f.write("const unsigned int parts_check[NPARTS * 24] = {\n")
        for i in range(0, len(hexw), 8):
            f.write("  " + ",".join("0x%06x" % v for v in hexw[i:i + 8]) + ",\n")
        f.write("};\n\n")
        # 元の色。kv_cell.spawn() は色を等しい確率で選ぶので、割合は色の数で等分する
        f.write("const unsigned char kind_orig[NKINDS][KCOLS][4] = {\n")
        for key in KINDS:
            cols = K.COLORS[key]
            w = 100 // len(cols)
            ent = []
            for j in range(NCOL):
                if j < len(cols):
                    h = cols[j].lstrip("#")
                    ent.append("{%d,%d,%d,%d}" % (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), w))
                else:
                    ent.append("{0,0,0,0}")
            f.write("  {" + ",".join(ent) + "},   /* %s */\n" % key)
        f.write("};\n")
    print("  vitis_src/parts_data.c / .h   %d 個 (pparts.hex と同じ並び)" % n)


if __name__ == "__main__":
    main()
