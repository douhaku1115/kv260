# -*- coding: utf-8 -*-
"""奥層/手前層の2層合成を入れると、参照実装との差がどれだけ縮まるかを測る。

参照実装 SCOPE_FS の該当部分:
    c  = p / TUBE_R                       手前層をサンプルする位置
    cB = (p + dir*sl*CELL_GAP) / TUBE_R   奥層はさらに CELL_GAP 進んだ位置
    F  = front(c)
    sh = front(c + (0.012,-0.016)).a      ぼかして影に使う
    B  = back(cB) * (1 - 0.5*sh)
    col = F.rgb + B*(1 - F.a)

光線を正規化していないので dir*sl はそのまま我々の dir になる。

  使い方:  python tools/two_layer_test.py
"""
import sys
import numpy as np
from PIL import Image
from scipy.ndimage import uniform_filter          # 影のぼかし用
sys.path.insert(0, "tools")
import ref_scope as R

CELL_GAP = 0.35


def fold_trace():
    """折り返しを回して、最終位置 p・方向 dir・反射回数・合わせ目・黒を返す"""
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
    return p, d, nrefl, seam, black, sp


def sample(img, c):
    n = img.shape[0]
    ix = np.clip(((c[..., 0] + 1) * 0.5 * n).astype(np.int32), 0, n - 1)
    iy = np.clip(((c[..., 1] + 1) * 0.5 * n).astype(np.int32), 0, n - 1)
    return img[iy, ix]


def shade(col, nrefl, seam, black, sp):
    col = col * (R.LOSS ** nrefl * seam)[..., None]
    col = np.where(black[..., None], np.array([0.01, 0.009, 0.013]), col)
    return np.clip(col * (1.0 - 0.3 * np.sum(sp * sp, -1))[..., None], 0, 1)


if __name__ == "__main__":
    back = np.asarray(Image.open("ref/dump/cell_back.png").convert("RGBA"), dtype=np.float64) / 255.0
    front = np.asarray(Image.open("ref/dump/cell_front.png").convert("RGBA"), dtype=np.float64) / 255.0
    ref = np.asarray(Image.open("ref/dump/scope_ref.png").convert("RGB"), dtype=np.int32)[::-1]

    p, d, nrefl, seam, black, sp = fold_trace()
    c  = p / R.TUBE_R
    cB = (p + d * CELL_GAP) / R.TUBE_R

    # 影は手前層のαをずらしてぼかしたもの (参照は lod+2 相当のぼかし)
    fa_blur = uniform_filter(front[..., 3], size=8)

    print("%-44s %-10s %s" % ("実装", "平均差", "16/255超"))

    # (1) 1枚に合成 (いまの RTL と同じ)
    comp = np.clip(front[..., :3] + back[..., :3] * (1 - front[..., 3:4]), 0, 1)
    out1 = shade(sample(comp, c), nrefl, seam, black, sp) * 255
    dd = np.abs(out1 - ref)
    print("%-44s %-10.2f %.1f%%" % ("1枚に合成 (いまの RTL)", dd.mean(), 100*(dd.max(-1) > 16).mean()))

    # (2) 2層。視差あり、影なし
    F = sample(front, c)
    B = sample(back[..., :3], cB)
    out2 = shade(F[..., :3] + B * (1 - F[..., 3:4]), nrefl, seam, black, sp) * 255
    dd = np.abs(out2 - ref)
    print("%-44s %-10.2f %.1f%%" % ("2層 + 視差", dd.mean(), 100*(dd.max(-1) > 16).mean()))

    # (3) 2層。視差 + 影
    sh = sample(fa_blur[..., None], c + np.array([0.012, -0.016]))[..., 0]
    out3 = shade(F[..., :3] + B * (1 - 0.5 * sh)[..., None] * (1 - F[..., 3:4]),
                 nrefl, seam, black, sp) * 255
    dd = np.abs(out3 - ref)
    print("%-44s %-10.2f %.1f%%" % ("2層 + 視差 + 影 (参照実装と同じ)", dd.mean(), 100*(dd.max(-1) > 16).mean()))

    Image.fromarray(out3.astype(np.uint8)).save("sim/two_layer.png")
    print("wrote sim/two_layer.png")
