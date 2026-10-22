# -*- coding: utf-8 -*-
"""きらめき層の固定小数点モデル（rtl/sparkle.v と 1 ビットも違わない計算）。

tools/sparkle_layer.py (浮動小数点の参照絵) の考えを、PL の段に合わせて整数で書いたもの。
テストベンチの正解 (vectors) と、実機に近い参照絵の両方に使う。

【入力】 cx, cy  … scope_pipe の O1 (回したあとのセル座標 c)。符号付き 18bit Q15、[-1,1]
【設定】 PS が AXI で渡す (kaleido_axi_slave の 0x1B0〜0x1E0)
    en     … 1 で出す
    lv     … 格子の 1 辺のマス数 = 2^lv (3〜7)。模様の大きさに合わせて PS が選ぶ
    dens   … マスに点がある割合 (0〜255 / 256)
    k      … (1 マスの画面画素 / 点の半径)^2 を Q8 で。点が画面で何画素に見えるかを決める
    base   … いつも光っている明るさ (128 = 1.0)
    flash  … キラッと光るときに足す明るさ (128 = 1.0)
    tphase … 時刻 (0〜255 で 1 周)。PS が毎フレーム進める
【出力】 r, g, b … 足し込む明るさ (0〜510)。α 合成の段で色に足し、255 で切る

【段】 (rtl/sparkle.v と同じ)
    P1  u = c + 1 を 0〜65535 に収め、マスの番号 gi と マスの中の位置 fr (Q16) に分ける
    P2  a  = (gx*0x9E37 ^ gy*0x7F4B) の下位 24bit
    P3  b  = a*0x5BD1E9 の下位 24bit、e = a*0x2C1B3 の下位 24bit
    P4  h  = b ^ (b>>11)、e2 = e ^ (e>>9)。点の有無・位置 (0.2〜0.8)・位相・速さ・色を切り出す
    P5  dx, dy = fr - 点の位置、t = (tphase*(4+速さ))>>2 + 位相
    P6  d2s = (dx^2 + dy^2) >> 16、tw = きらめきの表[t]
    P7  idx = (d2s*k) >> 18、s = base + (flash*tw)>>8
    P8  fall = 減衰の表[idx] (idx が 256 以上なら 0)
    P9  amt = (fall*s) >> 7 を 511 で切る
    P10 r,g,b = (amt*色) >> 8
"""
import math

import numpy as np

LAT = 10                    # 入力から出力までのクロック数

K1, K2 = 0x9E37, 0x7F4B
K3, K4 = 0x5BD1E9, 0x2C1B3
M24 = 0xFFFFFF

OFF0, OFFK = 13107, 154     # 点の位置 = 0.2 + 0.6*ox/255 (Q16)

# 色の表 (色の番号 0〜15)。段7b から PS が AXI で書く (0x1F0〜0x2E0)。
# 既定 (電源投入時) は段7 の 4 色 (白を 2 つにして白を多めに) の繰り返し
COLORS4 = [(255, 255, 255), (255, 255, 255), (255, 224, 140), (191, 217, 255)]
COLORS = [COLORS4[i % 4] for i in range(16)]

# 減衰の表: exp(-i/64)。i は (距離/点の半径)^2 の 64 倍
FALL_LUT = [int(round(255.0 * math.exp(-i / 64.0))) for i in range(256)]
# きらめきの表: (0.5 + 0.5 sin)^10。キラッと光る時間を短くする
TW_LUT = [int(round(255.0 * (0.5 + 0.5 * math.sin(2 * math.pi * i / 256.0)) ** 10))
          for i in range(256)]


def write_luts(path_fall, path_tw):
    with open(path_fall, "w") as f:
        for v in FALL_LUT:
            f.write("%02x\n" % v)
    with open(path_tw, "w") as f:
        for v in TW_LUT:
            f.write("%02x\n" % v)


def params_for_zoom(zoom, gap_px=7.0, dot_px=0.75, h=720, focal=0.85, z_cell=12.2, tube_r=2.25):
    """模様の大きさから lv と k を決める (PS の main.c と同じ式)"""
    c_per_px = (z_cell / tube_r) / (h * focal * zoom)       # 画面 1 画素ぶんの c
    want = 2.0 / (gap_px * c_per_px)
    lv = int(round(math.log2(want)))
    lv = max(3, min(7, lv))
    cell_px = 2.0 / (2 ** lv) / c_per_px
    k = int(round((cell_px / dot_px) ** 2 * 256.0))
    k = max(0, min(65535, k))
    return lv, k


def sparkle(cx, cy, en, lv, dens, k, base, flash, tphase, cols=None):
    """cx, cy は整数の配列 (符号付き Q15)。戻りは (r, g, b) の整数配列"""
    cx = np.asarray(cx, dtype=np.int64)
    cy = np.asarray(cy, dtype=np.int64)
    # P1
    ux = np.clip(cx + 32768, 0, 65535)
    uy = np.clip(cy + 32768, 0, 65535)
    sh = 16 - lv
    gx = ux >> sh
    gy = uy >> sh
    frx = (ux << lv) & 0xFFFF
    fry = (uy << lv) & 0xFFFF
    # P2
    a = ((gx * K1) ^ (gy * K2)) & M24
    # P3
    b = (a * K3) & M24
    e = (a * K4) & M24
    # P4
    h = b ^ (b >> 11)
    e2 = e ^ (e >> 9)
    have = (h & 0xFF) < dens
    offx = OFF0 + ((h >> 8) & 0xFF) * OFFK
    offy = OFF0 + ((h >> 16) & 0xFF) * OFFK
    ph = e2 & 0xFF
    rate = (e2 >> 8) & 3
    csel = (e2 >> 10) & 15
    # P5
    dx = frx - offx
    dy = fry - offy
    t = (((tphase * (4 + rate)) >> 2) + ph) & 0xFF
    # P6
    d2s = (dx * dx + dy * dy) >> 16
    tw = np.array(TW_LUT, dtype=np.int64)[t]
    # P7
    idx = (d2s * k) >> 18
    s = base + ((flash * tw) >> 8)
    # P8
    fall = np.where(idx < 256, np.array(FALL_LUT, dtype=np.int64)[np.minimum(idx, 255)], 0)
    # P9
    amt = np.minimum((fall * s) >> 7, 511)
    amt = np.where(have & (en != 0), amt, 0)
    # P10
    col = np.array(COLORS if cols is None else cols, dtype=np.int64)[csel]
    r = (amt * col[..., 0]) >> 8
    g = (amt * col[..., 1]) >> 8
    bb = (amt * col[..., 2]) >> 8
    return r, g, bb
