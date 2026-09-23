# -*- coding: utf-8 -*-
"""ピースの種類表（KV260 版）と、その描画負荷の見積もり。

参照実装 (ref/PIECES_THEMES.js) からの変更:
  ・星 を外し、六角柱 を入れる
  ・棒 を「縦横長さ比 1:1:3」にする（参照実装は約 1:1:6 の細長いカプセル）
  ・大きさの幅を広げる（参照実装は 1.6〜2.0 倍。ここは 3〜4 倍）

大きさの幅を広げても描画画素が増えないように、上を伸ばしたぶん下も下げる。
面積は r に比例するので、一様分布 [a,b] の r^2 の平均 (a^2+ab+b^2)/3 で比べる。

  使い方:  python tools/piece_table.py
"""

# key, 名前, 最大個数, rMin, rMax, sink, cr, 既定の個数
# sink: 重力の効き（負は浮く）  cr: 当たり判定の半径係数（0 はすり抜け）
KV_PIECES = [
    # key        名前        max  rMin   rMax   sink   cr    既定
    ("glass",    "色ガラス",  60, 0.060, 0.220, 0.15, 0.85,  16),
    ("rod",      "棒",        40, 0.080, 0.260, 0.20, 0.45,   3),
    ("hexprism", "六角柱",    20, 0.070, 0.200, 0.18, 0.50,   6),   # ← 星の代わり
    ("blob",     "丸い塊",    20, 0.060, 0.200, 0.12, 0.90,   5),
    ("crescent", "三日月",    20, 0.080, 0.240, 0.10, 0.70,   6),
    ("bead",     "ビーズ",    40, 0.025, 0.100, 0.28, 1.00,   8),
    ("stone",    "天然石",    20, 0.040, 0.140, 0.34, 1.00,   6),
    ("glitter",  "ラメ",     400, 0.006, 0.024, 0.03, 0.00, 220),
    ("bubble",   "気泡",       5, 0.030, 0.120, -0.3, 1.00,   1),
]

# 参照実装の表（比べるため）
REF_PIECES = [
    ("glass",    "色ガラス",  60, 0.090, 0.180,  16),
    ("rod",      "棒",        40, 0.120, 0.220,  10),
    ("star",     "星",        20, 0.060, 0.100,   0),
    ("blob",     "丸い塊",    20, 0.090, 0.150,   5),
    ("crescent", "三日月",    20, 0.110, 0.190,   6),
    ("bead",     "ビーズ",    40, 0.040, 0.070,   8),
    ("stone",    "天然石",    20, 0.060, 0.100,   0),
    ("glitter",  "ラメ",     400, 0.009, 0.018, 220),
    ("bubble",   "気泡",       5, 0.050, 0.080,   1),
]

CELL_PX = 256
PIX_CLK = 74.25e6
FPS     = 60.0
CORES   = 8          # 演算器の数
EVERY   = 2          # 何フレームに1回セルを描き直すか
NEED    = 45         # 一番重い種類が要る命令数


def mean_r2(a, b):
    """一様分布 [a,b] の r^2 の平均"""
    return (a * a + a * b + b * b) / 3.0


def area_px(key, a, b, n):
    """n 個ぶんの描画画素数。z による拡大 (0.85+0.3z) の平均は約 1.0"""
    pad = 2.6 if key == "glitter" else 1.2
    side2 = (2.0 * pad * (CELL_PX / 2.0)) ** 2 * mean_r2(a, b)
    return side2 * n


def report(title, rows, cnt_idx):
    print(title)
    print("  種類        個数    rMin   rMax   幅    総画素")
    total = 0.0
    for r in rows:
        key, name, mx, a, b = r[0], r[1], r[2], r[3], r[4]
        n = r[cnt_idx]
        px = area_px(key, a, b, n)
        total += px
        print("  %-9s %5d  %.3f  %.3f  %.1f倍 %9d" % (name, n, a, b, b / a, px))
    print("  %-9s %5d %31d" % ("合計", sum(r[cnt_idx] for r in rows), total))
    print()
    return total


def main():
    print("セル %dx%d、演算器 %d 個、%d フレームに1回描き直す\n" % (CELL_PX, CELL_PX, CORES, EVERY))

    ref_total = report("【参照実装の表・既定の個数】", REF_PIECES, 5)
    kv_total  = report("【KV260 の表・既定の個数】",   KV_PIECES, 7)

    print("既定の個数での描画画素:  参照 %d → KV260 %d  (%.0f%%)"
          % (ref_total, kv_total, 100.0 * kv_total / ref_total))
    print()

    # 最大個数まで積んだとき
    ref_max = sum(area_px(r[0], r[3], r[4], r[2]) for r in REF_PIECES)
    kv_max  = sum(area_px(r[0], r[3], r[4], r[2]) for r in KV_PIECES)
    print("最大個数 (%d 個) での描画画素:  参照 %d → KV260 %d  (%.0f%%)"
          % (sum(r[2] for r in KV_PIECES), ref_max, kv_max, 100.0 * kv_max / ref_max))
    print()

    print("演算器 %d 個のとき、1画素あたり使える命令数 (一番重い種類で %d 要る)" % (CORES, NEED))
    print("  描き直し間隔    既定 %d 個    最大 %d 個"
          % (sum(r[7] for r in KV_PIECES), sum(r[2] for r in KV_PIECES)))
    for every in (1, 2, 3, 4):
        b = PIX_CLK / FPS * every * CORES
        print("  %d フレームに1回 (%2dHz)  %6.0f %s   %6.0f %s"
              % (every, round(FPS / every),
                 b / kv_total, "○" if b / kv_total >= NEED else "×",
                 b / kv_max,   "○" if b / kv_max   >= NEED else "×"))



if __name__ == "__main__":
    main()
