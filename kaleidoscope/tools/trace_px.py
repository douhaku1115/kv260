# -*- coding: utf-8 -*-
"""1画素だけ float と固定小数点を並べて追跡する。ずれる場所を特定するため。

  使い方:  python tools/trace_px.py [x] [y]
"""
import sys
import numpy as np
sys.path.insert(0, "tools")
import ref_scope as R
import fx_scope as F

X = int(sys.argv[1]) if len(sys.argv) > 1 else 200
Y = int(sys.argv[2]) if len(sys.argv) > 2 else 200
W, H = R.W, R.H

walls, verts = R.mirror_geometry(R.POINTS)
wn = np.array([[w[0], w[1]] for w in walls])
wd = np.array([w[2] for w in walls])
NX = F.to_fx([w[0] for w in walls], F.N_F, F.N_B)
NY = F.to_fx([w[1] for w in walls], F.N_F, F.N_B)
WD = F.to_fx([w[2] for w in walls], F.A_F, F.A_B)

spx = (X + 0.5 - 0.5 * W) / H
spy = (0.5 * H - (Y + 0.5)) / H
slope = np.array([spx / R.FOCAL, spy / R.FOCAL])

# ---- float ----
p = slope * R.Z_MIRROR
d = slope.copy()
remain = R.Z_CELL - R.Z_MIRROR
fl = []
for i in range(20):
    dn = wn @ d
    a = np.maximum(wd - wn @ p, 0.0)
    t = np.where(dn > 1e-12, a / np.where(dn > 1e-12, dn, 1.0), np.inf)
    wi = int(np.argmin(t))
    if not np.isfinite(t[wi]) or t[wi] >= remain:
        p = p + d * remain
        fl.append(("end", i, p.copy(), None, remain))
        break
    p = p + d * t[wi]
    remain -= t[wi]
    d = d - 2 * (d @ wn[wi]) * wn[wi]
    fl.append(("hit", i, p.copy(), wi, remain))

# ---- fixed ----
def q(v, f):
    return v / float(1 << f)

slx = int(F.to_fx(slope[0], F.P_F, F.P_B))
sly = int(F.to_fx(slope[1], F.P_F, F.P_B))
zm = int(round(R.Z_MIRROR * (1 << 16)))
px_ = (slx * zm) >> 16
py_ = (sly * zm) >> 16
dx, dy = slx, sly
rem = int(round((R.Z_CELL - R.Z_MIRROR) * (1 << F.Q_F)))
fx = []
for i in range(20):
    A = [max(int(WD[w]) - ((px_ * int(NX[w]) + py_ * int(NY[w])) >> (F.P_F + F.N_F - F.A_F)), 0)
         for w in range(3)]
    DN = [(dx * int(NX[w]) + dy * int(NY[w])) >> (F.P_F + F.N_F - F.D_F) for w in range(3)]
    best, has = 0, DN[0] > 0
    for w in (1, 2):
        if DN[w] > 0 and ((not has) or A[w] * DN[best] < A[best] * DN[w]):
            best = w
        has = has or DN[w] > 0
    if (not has) or (A[best] << (F.Q_F + F.D_F - F.A_F)) >= rem * DN[best]:
        px_ += (dx * rem) >> F.Q_F
        py_ += (dy * rem) >> F.Q_F
        fx.append(("end", i, (q(px_, F.P_F), q(py_, F.P_F)), None, q(rem, F.Q_F)))
        break
    qq = int(F.fx_div(np.array([A[best]]), np.array([DN[best]]))[0])
    px_ += (dx * qq) >> F.Q_F
    py_ += (dy * qq) >> F.Q_F
    rem -= qq
    two = DN[best] << 1
    ndx = dx - ((two * int(NX[best])) >> F.N_F)
    ndy = dy - ((two * int(NY[best])) >> F.N_F)
    dx, dy = ndx, ndy
    fx.append(("hit", i, (q(px_, F.P_F), q(py_, F.P_F)), best, q(rem, F.Q_F)))

print("pixel (%d,%d)  slope = (%.6f, %.6f)" % (X, Y, slope[0], slope[1]))
print("%-4s | %-5s %-9s %-9s %-3s %-8s | %-5s %-9s %-9s %-3s %-8s"
      % ("i", "fl", "px", "py", "w", "remain", "fx", "px", "py", "w", "remain"))
for i in range(max(len(fl), len(fx))):
    a = fl[i] if i < len(fl) else ("-", i, (0, 0), None, 0)
    b = fx[i] if i < len(fx) else ("-", i, (0, 0), None, 0)
    print("%-4d | %-5s %-9.5f %-9.5f %-3s %-8.4f | %-5s %-9.5f %-9.5f %-3s %-8.4f"
          % (i, a[0], a[2][0], a[2][1], a[3], a[4], b[0], b[2][0], b[2][1], b[3], b[4]))
