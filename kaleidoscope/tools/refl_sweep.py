# -*- coding: utf-8 -*-
"""反射回数をパラメータ空間全体で測る。

ポイント数 3〜12、zoom 0.5〜2.5、視線の傾き 0〜0.9rad を振って、
「何段のパイプラインが要るか」を決めるための表を出す。

  使い方:  python tools/refl_sweep.py
"""
import sys
import math
import numpy as np
sys.path.insert(0, "tools")
import ref_scope as R

W, H = 640, 360           # 分布を見るだけなので半分の解像度で十分
MAXN = 200


def view_matrix(tx, ty):
    a = math.hypot(tx, ty)
    s = 1.0 if a < 1e-6 else math.sin(a) / a
    f = np.array([tx * s, ty * s, math.cos(a)])
    r = np.array([f[2], 0.0, -f[0]])
    r = r / np.linalg.norm(r)
    up = np.cross(f, r)
    return np.stack([r, up, f])        # 行が r, up, f


def measure(points, zoom, tilt, mirror=3):
    walls, verts = R.mirror_geometry(points)
    wn = np.array([[w[0], w[1]] for w in walls])
    wd = np.array([w[2] for w in walls])
    focal = 0.85 * zoom

    px, py = np.meshgrid(np.arange(W), np.arange(H))
    sp = np.stack([(px + .5 - .5 * W) / H, (.5 * H - (py + .5)) / H], -1)
    rd = np.concatenate([sp, np.full(sp.shape[:2] + (1,), focal)], -1)
    if tilt != 0.0:
        rd = rd @ view_matrix(tilt, 0.0).T

    ok = rd[..., 2] > 1e-3
    slope = rd[..., :2] / np.maximum(rd[..., 2:3], 1e-3)

    p = slope * R.Z_MIRROR
    d = slope.copy()                              # 正規化しない
    remain = np.full(p.shape[:2], R.Z_CELL - R.Z_MIRROR)
    n = np.zeros(p.shape[:2])
    done = ~ok
    for w in range(3):
        done |= (p @ wn[w]) > wd[w]               # 三角形の外 = 筒の縁

    for _ in range(MAXN):
        dn = np.stack([d @ wn[w] for w in range(3)], -1)
        a = np.maximum(np.stack([wd[w] - (p @ wn[w]) for w in range(3)], -1), 0.0)
        valid = dn > 1e-12
        t = np.where(valid, a / np.where(valid, dn, 1.0), np.inf)
        wi = np.argmin(t, -1)
        tb = np.take_along_axis(t, wi[..., None], -1)[..., 0]
        hit = (~done) & np.isfinite(tb) & (tb < remain)
        done |= (~done) & (~hit)
        if not hit.any():
            break
        p = np.where(hit[..., None], p + d * tb[..., None], p)
        remain = np.where(hit, remain - tb, remain)
        if mirror < 2.5:
            bottom = hit & (wi == 2)
            done |= bottom
            hit &= ~bottom
        ns = wn[wi]
        d = np.where(hit[..., None], d - 2 * np.sum(d * ns, -1, keepdims=True) * ns, d)
        n = np.where(hit, n + 1, n)

    return n


if __name__ == "__main__":
    print("反射回数（3ミラー）  各セル = 最大 / 99.9%%の画素が収まる回数 / 平均")
    print("%-8s" % "points", end="")
    zooms = [0.5, 1.0, 1.5, 2.5]
    for z in zooms:
        print("  zoom=%-16s" % z, end="")
    print()
    for pts in range(3, 13):
        print("%-8d" % pts, end="")
        for z in zooms:
            n = measure(pts, z, 0.0)
            p999 = int(np.percentile(n, 99.9))
            print("  %3d / %3d / %5.1f      " % (int(n.max()), p999, n.mean()), end="")
        print()

    print()
    print("視線の傾きを入れた場合 (points=8, zoom=1.0)")
    for tilt in [0.0, 0.3, 0.6, 0.9]:
        n = measure(8, 1.0, tilt)
        print("  傾き %.1f rad : 最大 %3d  99.9%% %3d  平均 %.1f"
              % (tilt, int(n.max()), int(np.percentile(n, 99.9)), n.mean()))

    print()
    print("最悪の組み合わせ (points=12, zoom=0.5, 傾き0.9)")
    n = measure(12, 0.5, 0.9)
    print("  最大 %d  99.9%% %d  99%% %d  平均 %.1f"
          % (int(n.max()), int(np.percentile(n, 99.9)), int(np.percentile(n, 99)), n.mean()))
