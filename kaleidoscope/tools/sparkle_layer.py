# -*- coding: utf-8 -*-
"""きらめき層の参照絵（段7 の下調べ）。

模様を大きくすると、セル (256x256) の 1 画素が画面で拡大されて、細かい粒が
点でなく塊になる。そこで、折り返したあとの細かい座標 (Q15、1 画素の 1/256 まで
ある) の上に格子を敷き、格子のマスごとに光る点を 1 つ置いて、画面の画素の細かさで描く。

  ・マスごとに、点があるか・マスの中の位置・光る時刻・色をハッシュで決める
  ・点の大きさは画面の画素で決める (模様を大きくしても点は大きくならない)
  ・格子の細かさは模様の大きさで 2 のべき乗に切り替え、画面上の点の間隔をほぼ一定にする
  ・点は折り返しの前のセル座標に置くので、模様と同じく鏡に映り、筒と一緒に回る
  ・明るさは「奥層と手前層を重ねた色」に足し、そのあと反射の減光・周辺減光を掛ける

PL では scope_pipe の O1 (回したあとの c) から分岐し、ハッシュ・距離・きらめきの表を
引いて、rtl_top の α 合成の段で足す形を想定する。

  使い方:  python tools/sparkle_layer.py     sim/spk_*.png と sim/spk_crop.png
"""
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ref_scope as R
import kv_cell as K

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CELL = 256

# ---- きらめき層の決め事 ----
GAP_PX   = 7.0     # 画面上の点の間隔のめやす (画素)。格子の 1 マスがこれくらいになるよう選ぶ
DENSITY  = 0.45    # マスに点がある割合
DOT_PX   = 0.75    # 点の半径 (画面の画素)。exp(-(d/DOT_PX)^2)
BASE     = 0.20    # いつも光っている明るさ
FLASH    = 1.60    # キラッと光るときに足す明るさ
SHARP    = 10      # 光る時間の短さ。(0.5+0.5 sin)^SHARP
SPEED    = 2.0     # 光る速さ (rad/s のめやす)
MARGIN   = 0.2     # 点をマスの縁から離す割合 (隣のマスを調べなくて済むように)
COLORS   = np.array([[1.0, 1.0, 1.0], [1.0, 1.0, 1.0], [1.0, 0.88, 0.55], [0.75, 0.85, 1.0]])


def fold_uv(cell, zoom):
    """cell_res_test.fold と同じ折り返し。色と一緒に、点を置く座標などを返す"""
    n = cell.shape[0]
    walls, verts = R.mirror_geometry(R.POINTS)
    wn = np.array([[w[0], w[1]] for w in walls])
    wd = np.array([w[2] for w in walls])
    W, H = R.W, R.H
    px, py = np.meshgrid(np.arange(W), np.arange(H))
    sp = np.stack([(px + .5 - .5 * W) / H, (.5 * H - (py + .5)) / H], -1)
    slope = sp / (R.FOCAL * zoom)
    p = slope * R.Z_MIRROR
    d = slope.copy()
    remain = np.full(p.shape[:2], R.Z_CELL - R.Z_MIRROR)
    nrefl = np.zeros(p.shape[:2])
    seam = np.ones(p.shape[:2])
    done = np.zeros(p.shape[:2], bool)
    for w in range(3):
        done |= (p @ wn[w]) > wd[w]
    black = done.copy()
    for _ in range(R.MAX_REFL):
        dn = np.stack([d @ wn[w] for w in range(3)], -1)
        a = np.maximum(np.stack([wd[w] - (p @ wn[w]) for w in range(3)], -1), 0.0)
        valid = dn > 1e-12
        t = np.where(valid, a / np.where(valid, dn, 1.0), np.inf)
        wi = np.argmin(t, -1)
        tb = np.take_along_axis(t, wi[..., None], -1)[..., 0]
        hit = (~done) & np.isfinite(tb) & (tb < remain)
        fin = (~done) & (~hit)
        p = np.where(fin[..., None], p + d * remain[..., None], p)
        done |= fin
        if not hit.any():
            break
        p = np.where(hit[..., None], p + d * tb[..., None], p)
        remain = np.where(hit, remain - tb, remain)
        dv2 = np.min(np.stack([np.sum((p - np.array(v)) ** 2, -1) for v in verts], -1), -1)
        e = 0.03 + 0.004 * nrefl
        u = np.clip(np.sqrt(dv2) / np.maximum(e, 1e-9), 0, 1)
        seam = np.where(hit, seam * (0.35 + 0.65 * (u * u * (3 - 2 * u))), seam)
        ns = wn[wi]
        d = np.where(hit[..., None], d - 2 * np.sum(d * ns, -1, keepdims=True) * ns, d)
        nrefl = np.where(hit, nrefl + 1, nrefl)
    p = np.where((~done)[..., None], p + d * remain[..., None], p)
    c = p / R.TUBE_R
    ix = np.clip(((c[..., 0] + 1) * 0.5 * n).astype(np.int32), 0, n - 1)
    iy = np.clip(((c[..., 1] + 1) * 0.5 * n).astype(np.int32), 0, n - 1)
    col = cell[iy, ix]
    gain = (R.LOSS ** nrefl * seam) * (1.0 - 0.3 * np.sum(sp * sp, -1))
    return col, c, gain, black


def grid_cells(zoom):
    """格子の 1 辺のマス数 (2 のべき乗)。1 マスが画面で GAP_PX 画素くらいになるもの"""
    c_per_px = (R.Z_CELL / R.TUBE_R) / (R.H * R.FOCAL * zoom)   # 画面 1 画素ぶんの c
    want = 2.0 / (GAP_PX * c_per_px)
    n = 2 ** int(round(np.log2(want)))
    return n, c_per_px


def hash32(gx, gy):
    """PL で作りやすいハッシュ (掛け算 2 回と xor)。gx, gy は 0〜1023"""
    h = (gx.astype(np.uint64) * 0x9E37 ^ gy.astype(np.uint64) * 0x7F4B) & 0xFFFFFF
    h = (h * 0x5BD1E9) & 0xFFFFFFFF
    h ^= h >> 13
    h = (h * 0x2C1B3) & 0xFFFFFFFF
    h ^= h >> 15
    return h


def sparkle(c, zoom, t):
    """画素ごとのきらめきの色 (足し込む量)"""
    n, c_per_px = grid_cells(zoom)
    g = (c + 1.0) * 0.5 * n                       # 格子の座標 (0〜n)
    gi = np.floor(g).astype(np.int64)
    fr = g - gi                                   # マスの中の位置 0〜1
    gi = np.clip(gi, 0, n - 1)
    h = hash32(gi[..., 0], gi[..., 1])
    have = ((h & 0xFF) / 256.0) < DENSITY
    ox = MARGIN + (1 - 2 * MARGIN) * (((h >> 8) & 0xFF) / 255.0)
    oy = MARGIN + (1 - 2 * MARGIN) * (((h >> 16) & 0xFF) / 255.0)
    ph = ((h >> 24) & 0x3F) / 64.0 * 2 * np.pi
    rate = 0.6 + 0.4 * (((h >> 30) & 0x3) / 3.0)
    cell_px = 2.0 / n / c_per_px                  # 1 マスが画面で何画素か
    dx = (fr[..., 0] - ox) * cell_px
    dy = (fr[..., 1] - oy) * cell_px
    fall = np.exp(-(dx * dx + dy * dy) / (DOT_PX * DOT_PX))
    tw = (0.5 + 0.5 * np.sin(t * SPEED * rate + ph)) ** SHARP
    amt = np.where(have, fall * (BASE + FLASH * tw), 0.0)
    col = COLORS[(h >> 6) & 3]
    return amt[..., None] * col, n, cell_px


def sparkle_fx(c, zoom, t):
    """PL と同じ固定小数点モデル (tools/sparkle_fx.py) で描く"""
    import sparkle_fx as F
    lv, k = F.params_for_zoom(zoom, GAP_PX, DOT_PX)
    q = np.clip(np.round(c * 32768.0), -131072, 131071).astype(np.int64)
    tphase = int(round(t * SPEED / (2 * np.pi) * 256.0)) & 0xFF
    r, g, b = F.sparkle(q[..., 0], q[..., 1], 1, lv, int(DENSITY * 256), k,
                        int(BASE * 128), int(FLASH * 128), tphase)
    add = np.stack([r, g, b], -1) / 255.0
    n, c_per_px = grid_cells(zoom)
    return add, 2 ** lv, 2.0 / (2 ** lv) / c_per_px


def main():
    use_fx = "--fx" in sys.argv
    parts = K.make_parts(random.Random(3), False)
    back, front = K.render(parts, CELL)
    cell = np.clip(front[..., :3] + back[..., :3] * (1.0 - front[..., 3:4]), 0, 1)
    shots = []
    t = 1.3
    for zoom in (1.0, 2.5):
        base, c, gain, black = fold_uv(cell, zoom)
        add, n, cpx = (sparkle_fx if use_fx else sparkle)(c, zoom, t)
        for tag, col in (("off", base), ("on", base + add)):
            img = np.clip(col * gain[..., None], 0, 1)
            img = np.where(black[..., None], np.array([0.01, 0.009, 0.013]), img)
            im = Image.fromarray((img * 255 + 0.5).astype(np.uint8))
            name = "z%d_%s" % (int(zoom * 100), tag)
            im.save(os.path.join(ROOT, "sim", "spk_%s.png" % name))
            shots.append((name, im))
        print("  大きさ %3d: 格子 %d マス、1 マス = 画面 %.1f 画素" % (zoom * 100, n, cpx))

    cw, ch = 400, 300
    w, h = shots[0][1].size
    box = (w // 2 - cw // 2 - 220, h // 2 - ch // 2 - 60, w // 2 + cw // 2 - 220, h // 2 + ch // 2 - 60)
    sheet = Image.new("RGB", (cw * 2, ch * 2))
    for i, (name, im) in enumerate(shots):
        x, y = (i % 2) * cw, (i // 2) * ch
        sheet.paste(im.crop(box), (x, y))
        ImageDraw.Draw(sheet).text((x + 6, y + 6), name, fill=(255, 255, 255))
    out = os.path.join(ROOT, "sim", "spk_fx_crop.png" if use_fx else "spk_crop.png")
    sheet.save(out)
    print("  見比べ → %s" % out)


if __name__ == "__main__":
    main()
