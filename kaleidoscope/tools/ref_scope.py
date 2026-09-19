# -*- coding: utf-8 -*-
"""
参照実装 SCOPE_FS (E:/Dropbox/claude/APP/kaleidoscope/index.html 754-816行) を
Python の浮動小数点でそのまま書き写したもの。

目的は2つ。
  1. Verilog を書く前に、アルゴリズムの理解が正しいか目で確かめる
  2. 固定小数点版 (段2) と見比べるための「正解画像」を作る

  使い方:  python tools/ref_scope.py [出力PNG]
"""
import sys
import math
import numpy as np
from PIL import Image

W, H = 1280, 720
CELL_N = 512            # セル画像の一辺 (PL では URAM に置く)

# ---- 筒の寸法 (cm) ----
TUBE_R   = 2.25         # 筒の内側の半径 = セルの半径
Z_MIRROR = 0.3          # のぞき穴 → 鏡の手前の端
Z_CELL   = 12.2         # のぞき穴 → セル手前層
MIRROR_R = 2.05         # 鏡の三角形の外接円

POINTS   = 8            # ポイント数。頂角 = 180/POINTS 度
MIRROR   = 3            # 3 = 3枚鏡, 2 = 底辺は黒
FOCAL    = 0.85         # 画角 (zoom=1)
MAX_REFL = 20           # 最大反射回数
LOSS     = 0.92         # 1回の反射で残る光の割合 (= 1 - 0.2*fade, fade=0.4)


def mirror_geometry(points):
    """参照実装 mirrorGeometry() と同じ。壁3枚 (外向き法線 nx,ny と位置 d) と頂点3つ"""
    R = MIRROR_R
    al = math.pi / points
    A = (0.0, R)
    B = (R * math.cos(1.5 * math.pi - al), R * math.sin(1.5 * math.pi - al))
    C = (R * math.cos(1.5 * math.pi + al), R * math.sin(1.5 * math.pi + al))
    cen = ((A[0] + B[0] + C[0]) / 3.0, (A[1] + B[1] + C[1]) / 3.0)

    def wall(P, Q):
        ex, ey = Q[0] - P[0], Q[1] - P[1]
        l = math.hypot(ex, ey)
        ex, ey = ex / l, ey / l
        nx, ny = ey, -ex
        # 法線を外向きに揃える (重心と逆を向かせる)
        if (cen[0] - P[0]) * nx + (cen[1] - P[1]) * ny > 0:
            nx, ny = -nx, -ny
        return (nx, ny, P[0] * nx + P[1] * ny)

    walls = [wall(A, B), wall(A, C), wall(B, C)]   # [0][1]=長い鏡, [2]=底辺
    return walls, [A, B, C]


def make_test_cell(n=CELL_N):
    """段2 用のテストセル画像。半径1の円に、市松 + 色帯 + 同心円を描く"""
    y, x = np.mgrid[0:n, 0:n]
    u = (x + 0.5) / n * 2.0 - 1.0
    v = (y + 0.5) / n * 2.0 - 1.0
    r = np.hypot(u, v)
    ang = np.arctan2(v, u)

    checker = (((x // 32) + (y // 32)) & 1).astype(np.float32)
    sector = np.floor((ang + math.pi) / (2 * math.pi) * 12).astype(np.int32) % 12
    ring = np.floor(r * 6).astype(np.int32)

    palette = np.array([
        [230,  60,  60], [240, 150,  40], [240, 220,  70], [120, 210,  80],
        [ 60, 200, 180], [ 60, 140, 240], [110,  90, 230], [200,  80, 220],
        [240, 120, 170], [200, 200, 200], [ 90, 200, 120], [240, 180, 100],
    ], dtype=np.float32) / 255.0

    img = palette[sector]
    img = img * (0.55 + 0.45 * checker)[..., None]
    img = img * (0.6 + 0.4 * ((ring & 1) == 0))[..., None]
    img[r > 1.0] = 0.02                      # 円の外は暗く
    return img.astype(np.float32)


def sample_cell(cell, c):
    """c は [-1,1] のセル座標。範囲外は最近傍でクランプ (参照は CLAMP_TO_EDGE)"""
    n = cell.shape[0]
    uv = (c * 0.5 + 0.5) * n - 0.5
    ix = np.clip(np.rint(uv[..., 0]).astype(np.int32), 0, n - 1)
    iy = np.clip(np.rint(uv[..., 1]).astype(np.int32), 0, n - 1)
    return cell[iy, ix]


def render(view=None):
    walls, verts = mirror_geometry(POINTS)
    wn = np.array([[w[0], w[1]] for w in walls], dtype=np.float64)   # 外向き法線
    wd = np.array([w[2] for w in walls], dtype=np.float64)           # 法線方向の位置

    px, py = np.meshgrid(np.arange(W), np.arange(H))
    # gl_FragCoord は左下原点。画像は左上原点なので y を反転
    sp = np.stack([(px + 0.5 - 0.5 * W) / H,
                   (0.5 * H - (py + 0.5)) / H], axis=-1)

    rd = np.concatenate([sp, np.full(sp.shape[:2] + (1,), FOCAL)], axis=-1)
    if view is not None:
        rd = rd @ np.array(view, dtype=np.float64).T
    rd = rd / np.linalg.norm(rd, axis=-1, keepdims=True)

    slope = rd[..., :2] / np.maximum(rd[..., 2:3], 1e-3)

    p = slope * Z_MIRROR                     # 鏡の手前の端での位置
    black = rd[..., 2] < 1e-3
    for w in range(3):
        black |= (p @ wn[w]) > wd[w]         # 三角形の外 = 筒の縁

    sl = np.linalg.norm(slope, axis=-1)
    d = np.where(sl[..., None] > 1e-6, slope / np.maximum(sl, 1e-12)[..., None],
                 np.array([0.0, 1.0]))
    remain = sl * (Z_CELL - Z_MIRROR)
    nrefl = np.zeros_like(sl)
    seam = np.ones_like(sl)                  # 鏡の合わせ目による暗さ
    done = black.copy()

    for _ in range(MAX_REFL):
        # 3枚の壁との交差距離 t。dn > 0 のものだけが候補
        dn = np.stack([d @ wn[w] for w in range(3)], axis=-1)              # (H,W,3)
        num = np.stack([wd[w] - (p @ wn[w]) for w in range(3)], axis=-1)
        num = np.maximum(num, 0.0)
        valid = dn > 1e-7
        t = np.where(valid, num / np.where(valid, dn, 1.0), np.inf)
        wi = np.argmin(t, axis=-1)
        tb = np.take_along_axis(t, wi[..., None], axis=-1)[..., 0]

        hit = (~done) & np.isfinite(tb) & (tb < remain)
        # 当たらなかった画素はそこで終了 (残り距離を直進)
        fin = (~done) & (~hit)
        p = np.where(fin[..., None], p + d * remain[..., None], p)
        done |= fin
        if not hit.any():
            break

        p = np.where(hit[..., None], p + d * tb[..., None], p)
        remain = np.where(hit, remain - tb, remain)

        if MIRROR < 2.5:
            bottom = hit & (wi == 2)
            black |= bottom
            done |= bottom
            hit &= ~bottom

        # 鏡の合わせ目: 三角形の頂点に近いほど暗い線になる
        #   dv = 3頂点までの距離の最小値
        #   seam *= mix(0.35, 1.0, smoothstep(0, 0.03 + 0.004*n, dv))
        dv2 = np.min(np.stack([np.sum((p - np.array(v)) ** 2, -1) for v in verts], -1), -1)
        e = 0.03 + 0.004 * nrefl
        u = np.clip(np.sqrt(dv2) / np.maximum(e, 1e-9), 0.0, 1.0)
        f = 0.35 + 0.65 * (u * u * (3.0 - 2.0 * u))
        seam = np.where(hit, seam * f, seam)

        n_sel = wn[wi]                                                     # (H,W,2)
        dot = np.sum(d * n_sel, axis=-1, keepdims=True)
        d = np.where(hit[..., None], d - 2.0 * dot * n_sel, d)
        nrefl = np.where(hit, nrefl + 1.0, nrefl)

    # 残り距離を消化しきれなかった画素 (反射上限に達した) も進めておく
    p = np.where((~done)[..., None], p + d * remain[..., None], p)

    c = p / TUBE_R
    cell = make_test_cell()
    col = sample_cell(cell, c)

    col = col * (LOSS ** nrefl * seam)[..., None]
    col = np.where(black[..., None], np.array([0.01, 0.009, 0.013]), col)
    col = col * (1.0 - 0.3 * np.sum(sp * sp, axis=-1))[..., None]
    return np.clip(col, 0.0, 1.0)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "sim/ref_scope.png"
    img = render()
    Image.fromarray((img * 255.0 + 0.5).astype(np.uint8)).save(out)
    print("wrote", out)
