# -*- coding: utf-8 -*-
"""セル画像の解像度をいくつにすべきかを決める。

参照実装から取り出した本物のセル画像 (1024x1024) を 512 / 256 / 128 に縮め、
同じ折り返し計算に通して、1024 の結果とどれだけ違うかを測る。

折り返しの実装は共通なので、差は解像度だけに由来する。

  使い方:  python tools/cell_res_test.py
"""
import sys
import numpy as np
from PIL import Image
sys.path.insert(0, "tools")
import ref_scope as R


def load_composited():
    """奥層と手前層を1枚に合成した 1024x1024 を返す (手前層はプリマルチプライドα)"""
    back = np.asarray(Image.open("ref/dump/cell_back.png").convert("RGBA"), dtype=np.float64) / 255.0
    front = np.asarray(Image.open("ref/dump/cell_front.png").convert("RGBA"), dtype=np.float64) / 255.0
    return np.clip(front[..., :3] + back[..., :3] * (1.0 - front[..., 3:4]), 0, 1)


def shrink(img, n):
    k = img.shape[0] // n
    return img.reshape(n, k, n, k, 3).mean(axis=(1, 3))


def fold(cell):
    """ref_scope と同じ折り返しで、与えたセル画像を引いた 1280x720 を返す"""
    n = cell.shape[0]
    walls, verts = R.mirror_geometry(R.POINTS)
    wn = np.array([[w[0], w[1]] for w in walls])
    wd = np.array([w[2] for w in walls])

    W, H = R.W, R.H
    px, py = np.meshgrid(np.arange(W), np.arange(H))
    sp = np.stack([(px + .5 - .5 * W) / H, (.5 * H - (py + .5)) / H], -1)
    slope = sp / R.FOCAL

    p = slope * R.Z_MIRROR
    d = slope.copy()
    remain = np.full(p.shape[:2], R.Z_CELL - R.Z_MIRROR)
    nrefl = np.zeros(p.shape[:2])
    seam = np.ones(p.shape[:2])
    done = np.zeros(p.shape[:2], bool)
    for w in range(3):
        done |= (p @ wn[w]) > wd[w]
    black = done.copy()

    for stage in range(R.MAX_REFL):
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
    col = col * (R.LOSS ** nrefl * seam)[..., None]
    col = np.where(black[..., None], np.array([0.01, 0.009, 0.013]), col)
    col = col * (1.0 - 0.3 * np.sum(sp * sp, -1))[..., None]
    return np.clip(col, 0, 1)


if __name__ == "__main__":
    full = load_composited()
    base = fold(full)
    Image.fromarray((base * 255 + .5).astype(np.uint8)).save("sim/res_1024.png")
    print("セル1024 を基準にする")
    print("%-8s %-10s %-10s %s" % ("解像度", "BRAM36", "平均差", "16/255超の画素"))
    for n in (512, 256, 128):
        img = fold(shrink(full, n))
        Image.fromarray((img * 255 + .5).astype(np.uint8)).save("sim/res_%d.png" % n)
        d = np.abs(img - base) * 255
        bram = int(np.ceil(n * n * 16 / 36864))
        print("%-8d %-10d %-10.2f %.2f%%" % (n, bram, d.mean(), 100 * (d.max(-1) > 16).mean()))
