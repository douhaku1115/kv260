# -*- coding: utf-8 -*-
"""ピース演算器が使う表を作る。

  rtl/log2_lut.hex   log2(m)   m は 1.0〜2.0 の仮数。512 点、18bit
  rtl/exp2_lut.hex   2^f       f は 0〜1 の小数部。512 点、18bit
  rtl/atan_lut.hex   CORDIC の角度表 atan(2^-i)。16 点、24bit (S6.17)

この3つで pow / exp / sqrt / 逆数 / smoothstep の割り算 / atan2 / hypot /
sin / cos がすべて賄える。専用の除算器も平方根器も要らない。

  使い方:  python tools/gen_pcore_hex.py
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.join(HERE, "..", "rtl")

FRAC = 17                      # S6.17
ONE = 1 << FRAC
LUT_BITS = 11                  # 2048 点 (512 点だと pow(x,40) の誤差が 2/255 出る)
LUT_N = 1 << LUT_BITS
VAL_BITS = 18                  # 表の値の幅


def write_hex(name, vals, width):
    path = os.path.join(RTL, name)
    digits = (width + 3) // 4
    with open(path, "w") as f:
        for v in vals:
            f.write("%0*x\n" % (digits, v & ((1 << width) - 1)))
    print("  %-16s %4d 行 x %2d bit" % (name, len(vals), width))


def main():
    # ---- log2(m), m ∈ [1,2) → [0,1)。18bit の小数として持つ ----
    log2 = []
    for i in range(LUT_N):
        m = 1.0 + (i + 0.5) / LUT_N
        log2.append(int(round(math.log2(m) * (1 << VAL_BITS))) & ((1 << VAL_BITS) - 1))
    write_hex("log2_lut.hex", log2, VAL_BITS)

    # ---- 2^f, f ∈ [0,1) → [1,2)。先頭の 1 は省いて小数部だけ持つ ----
    exp2 = []
    for i in range(LUT_N):
        f = (i + 0.5) / LUT_N
        exp2.append(int(round((math.pow(2.0, f) - 1.0) * (1 << VAL_BITS))) & ((1 << VAL_BITS) - 1))
    write_hex("exp2_lut.hex", exp2, VAL_BITS)

    # ---- CORDIC の角度表 atan(2^-i)。S6.17 ----
    at = [int(round(math.atan(2.0 ** -i) * ONE)) & 0xFFFFFF for i in range(20)]
    write_hex("atan_lut.hex", at, 24)

    k = 1.0
    for i in range(16):
        k *= math.sqrt(1.0 + 4.0 ** -i)
    print("\n  CORDIC の利得 K = %.9f   1/K = %.9f  (S6.17 で %d)"
          % (k, 1.0 / k, int(round(ONE / k))))


if __name__ == "__main__":
    main()
