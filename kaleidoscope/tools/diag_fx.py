# -*- coding: utf-8 -*-
"""固定小数点版がどこでずれるかを切り分ける診断。

  (a) float 正規化あり (ref_scope.render の中身)
  (b) float 正規化なし (z を媒介変数にする書き方)   <- fx と同じ手順
  (c) 固定小数点

  (a) と (b) が一致すれば「正規化をやめた」のは正しい。
  (b) と (c) の差が量子化誤差。
"""
import sys
import numpy as np
sys.path.insert(0, "tools")
import ref_scope as R
import fx_scope as F

W, H = R.W, R.H


def final_p(mode, K=16):
    walls, verts = R.mirror_geometry(R.POINTS)
    wn = np.array([[w[0], w[1]] for w in walls])
    wd = np.array([w[2] for w in walls])

    px, py = np.meshgrid(np.arange(W), np.arange(H))
    spx = (px + 0.5 - 0.5 * W) / H
    spy = (0.5 * H - (py + 0.5)) / H
    slope = np.stack([spx / R.FOCAL, spy / R.FOCAL], -1)

    p = slope * R.Z_MIRROR
    if mode == "norm":
        sl = np.linalg.norm(slope, axis=-1)
        d = slope / np.maximum(sl, 1e-12)[..., None]
        remain = sl * (R.Z_CELL - R.Z_MIRROR)
    else:
        d = slope.copy()
        remain = np.full(p.shape[:2], R.Z_CELL - R.Z_MIRROR)

    n = np.zeros(p.shape[:2])
    done = np.zeros(p.shape[:2], bool)
    for _ in range(K):
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
        ns = wn[wi]
        dot = np.sum(d * ns, -1, keepdims=True)
        d = np.where(hit[..., None], d - 2 * dot * ns, d)
        n = np.where(hit, n + 1, n)
    p = np.where((~done)[..., None], p + d * remain[..., None], p)
    return p, n


pa, na = final_p("norm")
pb, nb = final_p("raw")
print("(a)norm vs (b)raw :  p max diff = %.3e cm   refl mismatch = %.4f%%"
      % (np.abs(pa - pb).max(), 100 * (na != nb).mean()))

imgc, nc = F.render(16)
# fx の最終 p を取り出すため render を少し真似る代わりに、反射回数で比較する
print("(b)raw vs (c)fx  :  refl mismatch = %.4f%%   平均|dn|=" % (100 * (nb != nc).mean()))

# 反射回数がずれた画素の分布
mism = (nb != nc)
ys, xs = np.nonzero(mism)
if len(ys):
    print("  ずれた画素 %d 個  例: " % len(ys), list(zip(xs[:5], ys[:5])))
    print("  中心からの距離(px)の中央値 %.0f" % np.median(np.hypot(xs - W / 2, ys - H / 2)))
