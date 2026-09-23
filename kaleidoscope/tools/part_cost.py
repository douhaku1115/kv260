# -----------------------------------------------------------------------------
# ピースのラスタライズ負荷を測る
#
#   ref/dump/parts.json (参照実装から吸い出した266個の実データ) を読み、
#   セルを CELL_PX 角で描くとして
#     ・種類ごとの個数
#     ・種類ごとの描画画素数 (四角形の面積の合計)
#     ・1フレームあたりの総画素数と、74.25MHz で使えるクロック数
#   を出す。段5c で「1画素あたり何クロック回せるか」を決めるための数字。
#
#   参照実装の頂点シェーダ (index.html PART_VS):
#     r   = part.r * uSize * (0.85 + 0.3*z)
#     pad = (type == 2) ? 2.6 : 1.2        ← ラメだけ光条のぶん広い
#     四角形の一辺 = 2*r*pad   (セルは半径1の円なので、画素では CELL_PX/2 倍)
# -----------------------------------------------------------------------------
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
PARTS = os.path.join(HERE, "..", "ref", "dump", "parts.json")

CELL_PX = 256          # PL が持つセル画像の一辺
U_SIZE  = 1.0          # 参照実装の既定値
PIX_CLK = 74.25e6      # 画素クロック
FPS     = 60.0

NAMES = {0: "beads", 1: "glass", 2: "lame", 3: "star", 4: "bubble",
         5: "stone", 6: "stick", 7: "blob", 8: "moon"}
JP    = {0: "ビーズ", 1: "色ガラス", 2: "ラメ", 3: "星", 4: "気泡",
         5: "天然石", 6: "棒", 7: "丸い塊", 8: "三日月"}

with open(PARTS, "r", encoding="utf-8") as f:
    d = json.load(f)
parts = d["parts"] if isinstance(d, dict) and "parts" in d else d

cnt  = {}
area = {}
for p in parts:
    t = int(p["type"])
    r = p["r"] * U_SIZE * (0.85 + 0.3 * p["z"])
    pad = 2.6 if t == 2 else 1.2
    side_px = 2.0 * r * pad * (CELL_PX / 2.0)     # 半径1 → CELL_PX/2 画素
    cnt[t] = cnt.get(t, 0) + 1
    area[t] = area.get(t, 0.0) + side_px * side_px

total_px = sum(area.values())
print("ピース %d 個、セル %dx%d で描くとき" % (len(parts), CELL_PX, CELL_PX))
print()
print("  種類        個数    総画素    1個あたり   全体に占める割合")
for t in sorted(cnt, key=lambda k: -area[k]):
    print("  %-10s %4d  %8d  %8.0f      %5.1f%%"
          % (JP[t], cnt[t], area[t], area[t] / cnt[t], 100.0 * area[t] / total_px))
print("  %-10s %4d  %8d" % ("合計", len(parts), total_px))
print()

budget = PIX_CLK / FPS
print("セル1枚を描くのに要る画素   %10d" % total_px)
print("60fps で1フレームのクロック %10d  (74.25MHz)" % budget)
print("→ 1画素あたり使えるクロック %10.1f" % (budget / total_px))
print()
for div in (2, 3, 4):
    print("セルを %d フレームに1回だけ描き直すなら  1画素あたり %5.1f クロック"
          % (div, budget * div / total_px))
print()

# 上限 645 個のとき (ユーザーが増やせる上限)。種類ごとの比率は既定のまま伸ばす
scale = 645.0 / len(parts)
print("ピースを上限 645 個に増やすと  総画素 %d、1画素あたり %.1f クロック (毎フレーム)"
      % (total_px * scale, budget / (total_px * scale)))
