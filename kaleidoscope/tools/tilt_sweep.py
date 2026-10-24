# -*- coding: utf-8 -*-
"""視線の傾き (段9) の範囲確認と固定小数点照合。
  1) 傾き 0〜0.9・8方向で、浮動小数点の slope の最大値 (三角形の内側の画素だけ) を測る
  2) fx_scope.render(view, s_shift) と ref_scope.render(view) の画像誤差を測る
  使い方:  python tools/tilt_sweep.py
"""
import sys
import numpy as np
sys.path.insert(0, "tools")
import ref_scope as R
import fx_scope as F


def float_slope_range(view):
    W, H = R.W, R.H
    px, py = np.meshgrid(np.arange(W), np.arange(H))
    sp = np.stack([(px + 0.5 - 0.5 * W) / H, (0.5 * H - (py + 0.5)) / H], -1)
    rd = np.concatenate([sp, np.full(sp.shape[:2] + (1,), R.FOCAL)], -1) @ view.T
    front = rd[..., 2] > 1e-3
    slope = rd[..., :2] / np.maximum(rd[..., 2:3], 1e-3)
    walls, _ = R.mirror_geometry(R.POINTS)
    p = slope * R.Z_MIRROR
    inside = front.copy()
    for w in walls:
        inside &= (p[..., 0] * w[0] + p[..., 1] * w[1]) <= w[2]
    m_all = np.abs(slope[front]).max() if front.any() else 0
    m_in = np.abs(slope[inside]).max() if inside.any() else 0
    return m_all, m_in, inside.mean()


print("--- 1) slope の範囲 (Q3.15 の上限 4.0) ---")
worst = 0
for mag in (0.0, 0.3, 0.6, 0.9):
    for k in range(8 if mag > 0 else 1):
        ang = k * np.pi / 4
        v = F.view_matrix(mag * np.cos(ang), mag * np.sin(ang))
        m_all, m_in, frac = float_slope_range(v)
        worst = max(worst, m_in)
        print("傾き %.1f 方向 %3d度: 前向き全体 %7.2f  三角形内 %5.2f  (内側 %.0f%%)"
              % (mag, k * 45, m_all, m_in, frac * 100))
print("三角形内の最大 slope = %.2f" % worst)

print("--- 2) 固定小数点との照合 ---")
#   参照は 20 回で打ち切って直進、こちらは 16 回で打ち切って黒なので、傾けるほど差が増える
for mag, ang in ((0.0, 0), (0.5, 30), (0.9, 0), (0.9, 90), (0.9, 225)):
    v = F.view_matrix(mag * np.cos(np.radians(ang)), mag * np.sin(np.radians(ang)))
    img, _ = F.render(16, view=v)
    ref = R.render(v)
    d = np.abs(img - ref)
    bad = (d.max(-1) > 8.0 / 255).mean()
    print("傾き %.1f 方向 %3d度: 平均誤差 %.3f/255  最大 %.1f/255  8/255超 %.2f%%"
          % (mag, ang, d.mean() * 255, d.max() * 255, bad * 100))
