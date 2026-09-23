# -*- coding: utf-8 -*-
"""1種類を大きく描いて形と陰影を確かめる。

  使い方:  python tools/one_piece.py hexprism [rot度]
"""
import math
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kv_cell as K

N = 420


def render(key, rot_deg=20.0, seed=0.31, z=0.8, r_rel=0.72):
    typ = K.KEY_TO_TYPE[key]
    pad = 2.6 if key == "glitter" else 1.2
    ix, iy = np.meshgrid(np.arange(N), np.arange(N))
    sx = (ix + 0.5) / N * 2.0 - 1.0
    sy = (iy + 0.5) / N * 2.0 - 1.0
    vqx, vqy = sx / r_rel, sy / r_rel
    rot = math.radians(rot_deg)
    ca, sa = math.cos(rot), math.sin(rot)
    qx = ca * vqx - sa * vqy
    qy = sa * vqx + ca * vqy
    col = K.hexcol(K.COLORS[key][0])
    p = {"type": typ, "key": key, "seed": seed, "z": z, "rot": rot, "col": col}
    rgb, a = K.shade_piece(p, qx, qy, vqx, vqy, 0.0)
    src = rgb if typ == K.GLITTER else rgb * a[..., None]
    keep = ((np.abs(vqx) <= pad) & (np.abs(vqy) <= pad))[..., None]
    bg = np.full((N, N, 3), 0.06)
    out = np.where(keep, src + bg * (1.0 - a[..., None]), bg)
    return np.clip(out, 0, 1)


def main():
    key = sys.argv[1] if len(sys.argv) > 1 else "hexprism"
    angles = [0.0, 20.0, 55.0, 90.0]
    sheet = np.full((N, N * len(angles) + 8 * (len(angles) - 1), 3), 0.02)
    for i, ang in enumerate(angles):
        x0 = i * (N + 8)
        sheet[:, x0:x0 + N] = render(key, ang)
    Image.fromarray((sheet * 255).astype(np.uint8)).save("sim/one_piece.png")
    print("sim/one_piece.png に出した (%s、向き %s 度)"
          % (key, " / ".join(str(int(a)) for a in angles)))


if __name__ == "__main__":
    main()
