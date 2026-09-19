# -*- coding: utf-8 -*-
"""Verilog が $readmemh で読む .hex を作る。

  rtl/recip_lut.hex  逆数表 512 エントリ x 19bit  (divq.v)
  rtl/cell_test.hex  テストセル画像 256x256 RGB565 (市松模様)

  PL が実際に焼き込むのは rtl/cell_init.hex。使いたい方をコピーすること:
      cp rtl/cell_test.hex rtl/cell_init.hex   テストパターン
      cp rtl/cell_real.hex rtl/cell_init.hex   参照実装から取り出した本物
  (cell_real.hex は tools/cell_from_dump.py が作る)

  使い方:  python tools/gen_hex.py
"""
import sys
import numpy as np
sys.path.insert(0, "tools")
import ref_scope as R
import seam_tables as ST

LUT_BITS = 9            # 512 エントリ
LUT_OUT_F = 17          # Q1.17
CELL_N = 256            # 段2〜4 のテストセル (BRAM に収めるため 256)


def gen_recip():
    """m = 0.5 + (i+0.5)/1024 に対する 1/m を Q1.17 で表にする。
       値は 1〜2 なので 19bit あれば足りる。"""
    lines = []
    for i in range(1 << LUT_BITS):
        m = 0.5 + (i + 0.5) / (1 << (LUT_BITS + 1))
        v = int(round((1 << LUT_OUT_F) / m))
        assert 0 <= v < (1 << 19), (i, v)
        lines.append("%05x" % v)
    return lines


def gen_cell():
    """ref_scope.make_test_cell と同じ絵を RGB565 で。
       セルの (0,0) は画像の左下。Verilog 側は iy をそのまま行番号に使うので、
       ここでも make_test_cell と同じ並び (行 0 = v が -1 側) にしておく。"""
    img = R.make_test_cell(CELL_N)
    r = np.clip(np.rint(img[..., 0] * 31), 0, 31).astype(np.int32)
    g = np.clip(np.rint(img[..., 1] * 63), 0, 63).astype(np.int32)
    b = np.clip(np.rint(img[..., 2] * 31), 0, 31).astype(np.int32)
    v = (r << 11) | (g << 5) | b
    return ["%04x" % x for x in v.ravel()]


def gen_seam():
    """鏡の合わせ目の表。u2 = (dv/e)^2 の上位 8bit -> 減光係数 f (Q8)"""
    return ["%03x" % v for v in ST.seam_lut()]


def gen_loss():
    """反射 n 回ぶんの減光 LOSS^n を Q8 (0..256) で。rtl_top の shading が使う。"""
    return ["%03x" % int(round((R.LOSS ** n) * 256)) for n in range(32)]


if __name__ == "__main__":
    with open("rtl/recip_lut.hex", "w") as f:
        f.write("\n".join(gen_recip()) + "\n")
    print("rtl/recip_lut.hex  %d entries" % (1 << LUT_BITS))

    with open("rtl/loss_lut.hex", "w") as f:
        f.write("\n".join(gen_loss()) + "\n")
    print("rtl/loss_lut.hex   32 entries (LOSS=%.2f)" % R.LOSS)

    with open("rtl/seam_lut.hex", "w") as f:
        f.write("\n".join(gen_seam()) + "\n")
    print("rtl/seam_lut.hex   %d entries" % (1 << ST.SEAM_LUT_BITS))

    cell = gen_cell()
    with open("rtl/cell_test.hex", "w") as f:
        f.write("\n".join(cell) + "\n")
    print("rtl/cell_test.hex  %d entries (%dx%d RGB565)" % (len(cell), CELL_N, CELL_N))
    print("  → 使うときは rtl/cell_init.hex にコピーする")
