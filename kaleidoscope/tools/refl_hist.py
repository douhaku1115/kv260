# -*- coding: utf-8 -*-
"""反射回数の分布を調べる。K段パイプラインの段数を決めるため。"""
import numpy as np, math, sys
sys.path.insert(0, "tools")
import ref_scope as R

R.MAX_REFL = 64
walls, verts = R.mirror_geometry(R.POINTS)
wn = np.array([[w[0], w[1]] for w in walls]); wd = np.array([w[2] for w in walls])

W, H = R.W, R.H
px, py = np.meshgrid(np.arange(W), np.arange(H))
sp = np.stack([(px + .5 - .5*W)/H, (.5*H - (py + .5))/H], axis=-1)
slope = sp / R.FOCAL                      # 傾き0なら rd.xy/rd.z = sp/focal

p = slope * R.Z_MIRROR
d = slope.copy()                          # 正規化しない (z を媒介変数にする)
remain = np.full(p.shape[:2], R.Z_CELL - R.Z_MIRROR)
n = np.zeros(p.shape[:2]); done = np.zeros(p.shape[:2], bool)

for _ in range(64):
    dn  = np.stack([d @ wn[w] for w in range(3)], -1)
    num = np.maximum(np.stack([wd[w] - (p @ wn[w]) for w in range(3)], -1), 0.0)
    valid = dn > 1e-7
    t = np.where(valid, num/np.where(valid, dn, 1.), np.inf)
    wi = np.argmin(t, -1); tb = np.take_along_axis(t, wi[...,None], -1)[...,0]
    hit = (~done) & np.isfinite(tb) & (tb < remain)
    done |= (~done) & (~hit)
    if not hit.any(): break
    p = np.where(hit[...,None], p + d*tb[...,None], p)
    remain = np.where(hit, remain - tb, remain)
    ns = wn[wi]; dot = np.sum(d*ns, -1, keepdims=True)
    d = np.where(hit[...,None], d - 2*dot*ns, d)
    n = np.where(hit, n+1, n)

h = np.bincount(n.astype(int).ravel(), minlength=65)
tot = n.size
acc = 0
print("反射回数  画素数      累積%")
for i, c in enumerate(h[:40]):
    if c == 0 and i > n.max(): break
    acc += c
    print(f"{i:5d} {c:10d} {100*acc/tot:9.3f}")
print("最大", int(n.max()), " 平均", n.mean())
