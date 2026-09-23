# -*- coding: utf-8 -*-
"""KV260 版のセル画像。段5c で PL に載せる形と陰影は、ここで決めたものにする。

`tools/ref_cell.py` が参照実装の忠実な移植（本物と平均 0.2/255 で一致を確認済み）。
こちらはそこからの変更版:

  ・星 を外し、六角柱 を入れる（星は atan と cos(5a) が要って重い。
    六角柱は atan が要らず、9種で一番軽い）
  ・棒 を縦横長さ比 1:1:3 にする（参照実装は約 1:1:6 の細長いカプセル）
  ・大きさの幅を 3〜4倍に広げる（参照実装は 1.6〜2.0倍）

  使い方:
    python tools/kv_cell.py              既定の個数で描く
    python tools/kv_cell.py --seed 7     乱数の種を変える
    python tools/kv_cell.py --max        上限の個数で描く
"""
import io
import json
import math
import os
import random
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ref_cell as R
from piece_table import KV_PIECES

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")

# 種類の番号。参照実装の並びを引き継ぎ、3番(星)を六角柱に置き換える
BEAD, GLASS, GLITTER, HEXPRISM, BUBBLE, STONE, ROD, BLOB, CRESCENT = range(9)

KEY_TO_TYPE = {
    "bead": BEAD, "glass": GLASS, "glitter": GLITTER, "hexprism": HEXPRISM,
    "bubble": BUBBLE, "stone": STONE, "rod": ROD, "blob": BLOB, "crescent": CRESCENT,
}

# 色は参照実装の「写真の色」テーマ。六角柱は星の色（金と銀）を引き継ぐ
COLORS = {
    "glass":    ["#1d3fd6", "#2f63f0", "#5a86ff", "#1a2c8f"],
    "rod":      ["#f2c230", "#e0a820"],
    "blob":     ["#58c43c", "#8ee05a"],
    "crescent": ["#f5f2ea", "#e6eef5"],
    "bead":     ["#3a6bff", "#f2c230", "#ffffff"],
    "stone":    ["#5f9e7a", "#8a6ad0", "#d9cfc0"],
    "hexprism": ["#e8b64a", "#c9cfd8"],
    "glitter":  ["#b58ae8", "#d9dde6", "#8f6fd8", "#ffffff", "#e6c8ff"],
    "bubble":   ["#e6f2ff"],   # 参照実装が色を無視して塗る (0.9,0.95,1.0) をそのまま持たせる
}

L = R.L


def hexcol(s):
    return [int(s[i:i + 2], 16) / 255.0 for i in (1, 3, 5)]


# ---- 形と陰影のうち、参照実装から変えたもの ----

def shade_rod(p, qx, qy, vqx, vqy, e, c):
    """棒（円柱）。縦横長さ比 1:1:3。

    半長 0.6 + 端の丸み 0.3 = 0.9、半径 0.3。0.9 / 0.3 = 3。
    参照実装は半長 0.96・半径 0.16 で 6:1 だった。
    陰影は円柱の断面 √(1 - cy²)。なめらかに丸い。
    """
    HALF, RAD = 0.6, 0.3
    d = np.hypot(np.maximum(np.abs(qx) - HALF, 0.0), qy) - RAD
    a = 1.0 - R.smoothstep(-e * 0.4, e * 0.4, d)
    cy = np.clip(qy / RAD, -1.0, 1.0)
    shade = np.sqrt(np.maximum(0.0, 1.0 - cy * cy))
    hl = np.power(np.maximum(0.0, 1.0 - np.abs(cy + 0.4) * 2.5), 3.0)
    rgb = c * (0.55 + 0.7 * shade)[..., None] + (hl * 0.8)[..., None]
    return rgb, a * 0.95


def shade_hexprism(p, qx, qy, vqx, vqy, e, c):
    """六角柱。縦横長さ比 1:1:3。星の代わりに入れたもの。

    輪郭は角のある箱（atan が要らない = 9種で一番軽い）。
    六角形の断面は「横に3本の平らな帯」として見える。帯ごとに面の向きが
    -60° / 0° / +60° と変わるので、明るさが段になる。
    棒（なめらかな円筒）との違いがここではっきり出る。
    """
    HALF, RAD = 0.9, 0.3
    d = np.maximum(np.abs(qx) - HALF, np.abs(qy) - RAD)
    a = 1.0 - R.smoothstep(-e, e, d)

    t = np.clip(qy / RAD, -1.0, 1.0)                 # -1 〜 1
    band = np.clip(np.floor((t + 1.0) * 1.5), 0, 2)  # 0, 1, 2 の3本
    # 軸まわりの転がり角。粒ごとに変える（seed）ので、どの面が光るかが1個ずつ違う。
    # 面内の回転しか持たない作りでも、これで角柱らしい表情の差が出る。
    roll = float(p["seed"]) * (np.pi / 3.0)          # 0〜60°。六角形は60°で1周
    th = (band - 1.0) * (np.pi / 3.0) + roll
    dif = np.maximum(np.sin(th) * L[1] + np.cos(th) * L[2], 0.0)
    # 鏡面を足して隣の面との差を開く。拡散だけだと 0.78 と 0.87 で見分けがつかない
    spec = np.power(dif, 12.0)
    shade = 0.20 + 0.80 * dif + 0.75 * spec

    edge = 1.0 - R.smoothstep(0.0, 0.05, np.abs(np.abs(t) - 1.0 / 3.0))  # 稜線
    cap = R.smoothstep(0.86, HALF, np.abs(qx))                           # 切り口
    rgb = c * (0.55 + 0.9 * shade)[..., None] + (edge * 0.30 + cap * 0.20)[..., None]
    return rgb, a * 0.90


REF_SHADE = R.shade_piece      # 差し替える前に本体を捕まえておく


def shade_piece(p, qx, qy, vqx, vqy, t):
    """KV260 版。棒と六角柱だけ差し替え、他は参照実装のまま"""
    typ = int(p["type"])
    z = float(p["z"])
    e = 0.1 + (0.025 - 0.1) * z
    depth_shade = 0.65 + (1.0 - 0.65) * z
    c = np.array(p["col"], dtype=np.float64)

    if typ == ROD:
        rgb, a = shade_rod(p, qx, qy, vqx, vqy, e, c)
        return rgb * depth_shade, a
    if typ == HEXPRISM:
        rgb, a = shade_hexprism(p, qx, qy, vqx, vqy, e, c)
        return rgb * depth_shade, a
    return REF_SHADE(p, qx, qy, vqx, vqy, t)


# ---- ピースを撒く（参照実装 spawn() と同じ散らし方） ----

def spawn(pc, rng):
    key, _, mx, rmin, rmax, sink, cr, _ = pc
    while True:
        x = rng.uniform(-0.9, 0.9)
        y = rng.uniform(-0.9, 0.9)
        if x * x + y * y <= 0.8:
            break
    typ = KEY_TO_TYPE[key]
    cols = COLORS[key]
    jit = rng.uniform(0.88, 1.08)
    col = [min(1.0, v * jit) for v in hexcol(cols[rng.randrange(1000) % len(cols)])]
    return {
        "type": typ, "key": key, "x": x, "y": y,
        "z": 0.95 if typ == BUBBLE else rng.random(),
        "r": rng.uniform(rmin, rmax),
        "rot": rng.uniform(0.0, 2.0 * math.pi),
        "seed": rng.random(),
        "col": col,
    }


def make_parts(rng, use_max=False):
    parts = []
    for pc in KV_PIECES:
        n = pc[2] if use_max else pc[7]
        for _ in range(n):
            parts.append(spawn(pc, rng))
    return parts


def render(parts, n, t=0.0, u_size=1.0):
    """ref_cell.render_cell と同じ手順。陰影だけ KV260 版に差し替える"""
    orig = R.shade_piece
    R.shade_piece = shade_piece          # draw_parts が呼ぶ先を入れ替える
    try:
        return R.render_cell(parts, n, t, u_size)
    finally:
        R.shade_piece = orig


def main():
    seed = 1
    if "--seed" in sys.argv:
        seed = int(sys.argv[sys.argv.index("--seed") + 1])
    use_max = "--max" in sys.argv
    n = 1024

    rng = random.Random(seed)
    parts = make_parts(rng, use_max)
    print("ピース %d 個、セル %dx%d、種 %d" % (len(parts), n, n, seed))

    back, front = render(parts, n)
    # 目で見るために1枚に合成する（手前層はプリマルチプライドα）
    comp = front[..., :3] + back[..., :3] * (1.0 - front[..., 3:4])
    Image.fromarray((np.clip(comp, 0, 1) * 255).astype(np.uint8)).save("sim/kv_cell.png")
    print("sim/kv_cell.png に出した")

    json.dump(parts, io.open(os.path.join(ROOT, "sim", "kv_parts.json"), "w",
                             encoding="utf-8"), ensure_ascii=False)


if __name__ == "__main__":
    main()
