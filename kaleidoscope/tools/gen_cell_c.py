# -*- coding: utf-8 -*-
"""セル画像を C の配列にする。

セル画像は URAM に置いたが、**URAM は初期値を持てない**
（`ram_style="ultra"` に `$readmemh` があると BRAM に落ちる。2025.2 で実測）。
そこで起動時に PS が AXI で流し込む。その配列をここで作る。

  vitis_src/cell_data.c   奥層 65536 x u16 (油の地) + 手前層 65536 x u32
  vitis_src/cell_data.h   宣言

将来 PL が 2 枚とも毎フレーム描くようになれば、この配列は要らなくなる。

  使い方:  python tools/gen_cell_c.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
N = 256 * 256


def read_hex(path, n):
    vals = []
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if ln:
                vals.append(int(ln, 16))
    if len(vals) != n:
        raise SystemExit("%s の行数が %d (%d のはず)" % (path, len(vals), n))
    return vals


def emit(f, name, typ, vals, width):
    f.write("const %s %s[%d] = {\n" % (typ, name, len(vals)))
    per = 12 if width == 4 else 8
    for i in range(0, len(vals), per):
        f.write("  " + "".join("0x%0*x," % (width, v) for v in vals[i:i + per]) + "\n")
    f.write("};\n\n")


def main():
    back = read_hex(os.path.join(ROOT, "rtl", "cell_oil.hex"), N)

    cpath = os.path.join(ROOT, "vitis_src", "cell_data.c")
    with open(cpath, "w") as f:
        f.write("/* tools/gen_cell_c.py が作る。手で直さない。\n"
                " *\n"
                " * セル画像は URAM に置いてあり、URAM は初期値を持てないので\n"
                " * 起動時に PS が AXI (0x180 CELL_CTRL / 0x190 CELL_DATA) で流し込む。\n"
                " *   cell_back  油の地だけ (この上に PL がピースを描く)  RGB565\n"
                " *\n"
                " * 段5d-5 から**手前層は PL が描く**ので、手前層の配列は要らなく\n"
                " * なった (256KB 減)。手前層の URAM は初期値 (全 0 = 透明) のまま\n"
                " * でよく、その上に PL がピースを描く。\n"
                " */\n"
                '#include "cell_data.h"\n\n')
        emit(f, "cell_back", "unsigned short", back, 4)

    hpath = os.path.join(ROOT, "vitis_src", "cell_data.h")
    with open(hpath, "w") as f:
        f.write("/* tools/gen_cell_c.py が作る */\n"
                "#ifndef CELL_DATA_H\n#define CELL_DATA_H\n"
                "#define CELL_N %d\n"
                "extern const unsigned short cell_back[CELL_N];\n"
                "#endif\n" % N)

    print("  vitis_src/cell_data.c  %.0f KB" % (os.path.getsize(cpath) / 1024))
    print("  vitis_src/cell_data.h")
    print("  ELF には 油の地 %d KB 増える (手前層は PL が描くので不要)"
          % (N * 2 // 1024))


if __name__ == "__main__":
    main()
