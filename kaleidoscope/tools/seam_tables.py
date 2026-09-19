# -*- coding: utf-8 -*-
"""鏡の合わせ目 (seam) に使う定数と表。fx_scope.py と gen_hex.py の両方から使う。

参照実装:
    dv    = 3頂点までの距離の最小値
    seam *= mix(0.35, 1.0, smoothstep(0.0, 0.03 + 0.004*n, dv))

固定小数点での組み方
    dv2  : 頂点までの距離の2乗。Q22 (p が Q15 なので積は Q30、8bit 右シフト)
    u2   : (dv/e)^2 を Q16 で。段ごとに e が決まるので 1/e^2 は定数
             u2 = dv2 * INV_E2[i] >> 12        INV_E2[i] = round(2^6 / e_i^2)
    f    : SEAM_LUT[u2 >> 8] で Q8 (0.35〜1.0 → 90〜256)
    seam : Q15。段ごとに seam = (seam * f) >> 8
"""

SEAM_LUT_BITS = 8          # 256 エントリ
SEAM_OUT_F = 8             # Q8
INV_E2_F = 6               # INV_E2 の小数ビット
DV2_F = 22                 # dv2 の小数ビット
U2_F = 16                  # u2 の小数ビット
SEAM_F = 15                # seam の小数ビット

SEAM_MIN = 0.35            # 合わせ目の一番暗いところ


def e_of(i):
    """i 段目 (= それまでの反射回数) の smoothstep の幅"""
    return 0.03 + 0.004 * i


def inv_e2(i):
    v = int(round((1 << INV_E2_F) / (e_of(i) ** 2)))
    assert v < (1 << 18), (i, v)
    return v


def seam_lut():
    """u2 (= (dv/e)^2, Q16 を 8bit に丸めたもの) → f を Q8 で"""
    out = []
    for idx in range(1 << SEAM_LUT_BITS):
        u2 = (idx + 0.5) / (1 << SEAM_LUT_BITS)
        u = min(u2 ** 0.5, 1.0)
        s = u * u * (3.0 - 2.0 * u)
        f = SEAM_MIN + (1.0 - SEAM_MIN) * s
        out.append(int(round(f * (1 << SEAM_OUT_F))))
    return out


U2_SHIFT = DV2_F + INV_E2_F - U2_F      # = 12
