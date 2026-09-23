# -*- coding: utf-8 -*-
"""参照実装の PART_FS / OIL_FS を Python の浮動小数点でそのまま書き写したもの。

段5c（ピースを PL で描く）の「正解」を作るための土台。
ここが `ref/dump/cell_back.png` / `cell_front.png` と一致して初めて、
形と陰影の理解が正しいと言える。合ってから六角柱などの変更を入れる。

  使い方:
    python tools/ref_cell.py            奥層・手前層を描いて本物と突き合わせる
    python tools/ref_cell.py --time 12  uTime を指定する

参照元: E:/Dropbox/claude/APP/kaleidoscope/index.html
    PART_VS 530-541行 / PART_FS 543-641行 / OIL_FS 644-654行 / renderCell 712-740行
"""
import io
import json
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
DUMP = os.path.join(ROOT, "ref", "dump")

# ---- PART_FS の定数 ----
L = np.array([-0.45, 0.55, 0.7])
L = L / np.linalg.norm(L)

# 種類の番号 (index.html 275行の T)
BEAD, GLASS, GLITTER, STAR, BUBBLE, STONE, ROD, BLOB, CRESCENT = range(9)


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def ngon(px, py, n):
    """正 n 角形までの距離。PART_FS の ngon() と同じ"""
    b = 2.0 * np.pi / n
    a = np.arctan2(py, px)
    s = np.floor(a / b + 0.5) * b
    return np.cos(a - s) * np.hypot(px, py)


def star_d(px, py):
    a = np.arctan2(py, px)
    k = 0.5 + 0.5 * np.cos(a * 5.0)
    return np.hypot(px, py) / (0.45 + 0.55 * k * k)


def oil_bg(n, t):
    """OIL_FS。暗いオイルの地。半径1の円に収まる正方形いっぱいに描く"""
    v, u = np.mgrid[0:n, 0:n]
    uv_x = (u + 0.5) / n
    uv_y = (v + 0.5) / n
    cx = uv_x * 2.0 - 1.0
    cy = uv_y * 2.0 - 1.0
    r = np.hypot(cx, cy)
    s = smoothstep(0.0, 1.0, r)[..., None]
    base = np.array([0.055, 0.045, 0.08]) * (1 - s) + np.array([0.02, 0.018, 0.03]) * s
    w = 0.5 + 0.5 * np.sin(cx * 3.1 + np.sin(cy * 2.3 + t * 0.15) * 1.7 + t * 0.1)
    rgb = base * (0.8 + 0.4 * w)[..., None]
    return np.concatenate([rgb, np.ones((n, n, 1))], axis=2)


def shade_piece(p, qx, qy, vqx, vqy, t):
    """PART_FS 本体。1個ぶんの (rgb, a) を返す。rgb はプリマルチプライド前"""
    typ = int(p["type"])
    seed = float(p["seed"])
    z = float(p["z"])
    c = np.array(p["col"], dtype=np.float64)

    e = 0.1 + (0.025 - 0.1) * z              # mix(0.1, 0.025, z) 奥ほどぼける
    depth_shade = 0.65 + (1.0 - 0.65) * z    # mix(0.65, 1.0, z)
    lq = np.hypot(vqx, vqy)

    def sphere_normal(nx, ny):
        """法線 (nx, ny, sqrt(1-|n|^2))。球に見せるための作りもの"""
        nz = np.sqrt(np.maximum(0.0, 1.0 - (nx * nx + ny * ny)))
        return nx, ny, nz

    def specular(nx, ny, nz, power):
        """pow(dot(reflect(-L, n), (0,0,1)), power)。reflect(I,N) = I - 2*dot(N,I)*N"""
        ndl = nx * L[0] + ny * L[1] + nz * L[2]
        rz = -L[2] + 2.0 * ndl * nz
        return np.power(np.maximum(rz, 0.0), power)

    if typ == BEAD:
        d = lq
        a = 1.0 - smoothstep(1.0 - e, 1.0 + e, d)
        den = np.maximum(d, 1.0)
        nqx, nqy = vqx / den, vqy / den
        nx, ny, nz = sphere_normal(nqx, nqy)
        dif = np.maximum(nx * L[0] + ny * L[1] + nz * L[2], 0.0)
        sp = specular(nx, ny, nz, 40.0)
        through = smoothstep(-0.2, 0.9, nqx * -L[0] + nqy * -L[1])
        rgb = (c * (0.3 + 0.55 * dif)[..., None]
               + c * (through * 0.7)[..., None]
               + (sp * 1.3)[..., None])

    elif typ == GLASS:
        px = qx * (1.0 + 0.45 * seed)
        py = qy * (1.0 - 0.20 * seed)
        v = ngon(px, py, 3.0 + np.floor(seed * 2.999))
        ap = 0.72
        a = 1.0 - smoothstep(ap - e, ap + e, v)
        edge = smoothstep(ap - 0.18, ap, v)
        pl = np.hypot(px, py) + 1e-4
        face = 0.5 + 0.5 * ((px / pl) * -L[0] + (py / pl) * -L[1]) * np.minimum(pl / ap, 1.0)
        rgb = c * (0.8 + 0.6 * face)[..., None] + (edge * 0.35)[..., None]
        a = a * (0.72 + 0.25 * edge)

    elif typ == GLITTER:
        v = ngon(qx, qy, 6.0)
        cov = 1.0 - smoothstep(0.85 - e * 2.0, 0.85 + e * 2.0, v)
        sp = np.power(0.5 + 0.5 * np.sin(p["rot"] * 4.0 + seed * 60.0
                                         + t * (0.3 + seed * 0.6)), 14.0)
        glow = sp * np.exp(-lq * 1.5) * 0.9
        flare = sp * (np.exp(-np.abs(vqx) * 12.0) + np.exp(-np.abs(vqy) * 12.0)) \
            * np.exp(-lq * 0.9) * 0.6
        rgb = ((c * 0.65 + sp * 1.4) * cov[..., None]
               + (c * 0.5 + 0.5) * (glow + flare)[..., None])
        a = np.clip(cov * 0.9 + glow + flare, 0.0, 1.0)
        # ★ ラメだけ rgb に a を掛けずに返す (参照実装がそうなっている)
        return rgb * depth_shade, a

    elif typ == STAR:
        v = star_d(qx, qy)
        a = 1.0 - smoothstep(0.92 - e, 0.92 + e, v)
        sh = 0.5 + 0.5 * np.sin(qx * 2.3 + qy * 1.7 + p["rot"] * 2.0 + seed * 9.0)
        rgb = c * (0.5 + 0.6 * sh)[..., None] \
            + np.array([1.0, 0.97, 0.85]) * (np.power(sh, 10.0) * 0.9)[..., None]

    elif typ == STONE:
        an = np.arctan2(qy, qx)
        rad = 0.84 + 0.08 * np.sin(an * 3.0 + seed * 20.0) + 0.05 * np.sin(an * 5.0 + seed * 37.0)
        d = np.hypot(qx, qy) / rad
        a = 1.0 - smoothstep(1.0 - e, 1.0 + e, d)
        nqx, nqy = vqx / rad, vqy / rad
        l2 = nqx * nqx + nqy * nqy
        sc = np.where(l2 > 1.0, 1.0 / np.sqrt(np.maximum(l2, 1e-12)), 1.0)
        nqx, nqy = nqx * sc, nqy * sc
        nx, ny, nz = sphere_normal(nqx, nqy)
        dif = np.maximum(nx * L[0] + ny * L[1] + nz * L[2], 0.0)
        band = np.sin((qx * np.cos(seed * 6.0) + qy * np.sin(seed * 6.0)) * 9.0
                      + np.sin(qx * 4.0 + seed * 11.0) * np.sin(qy * 5.0 - seed * 7.0) * 2.5
                      + seed * 30.0)
        m = smoothstep(-0.3, 0.9, band)[..., None]
        base = (c * 0.55) * (1 - m) + (c * 0.65 + 0.35) * m
        rgb = base * (0.4 + 0.8 * dif)[..., None] + (specular(nx, ny, nz, 24.0) * 0.5)[..., None]

    elif typ == ROD:
        d = np.hypot(np.maximum(np.abs(qx) - 0.8, 0.0), qy) - 0.16
        a = 1.0 - smoothstep(-e * 0.4, e * 0.4, d)
        cy = np.clip(qy / 0.16, -1.0, 1.0)
        shade = np.sqrt(np.maximum(0.0, 1.0 - cy * cy))
        hl = np.power(np.maximum(0.0, 1.0 - np.abs(cy + 0.4) * 2.5), 3.0)
        rgb = c * (0.55 + 0.7 * shade)[..., None] + (hl * 0.8)[..., None]
        a = a * 0.95

    elif typ == BLOB:
        an = np.arctan2(qy, qx)
        rad = 0.82 + 0.1 * np.sin(an * 3.0 + seed * 17.0) + 0.06 * np.sin(an * 5.0 + seed * 29.0)
        d = np.hypot(qx, qy) / rad
        a = 1.0 - smoothstep(1.0 - e, 1.0 + e, d)
        core = np.clip(1.0 - d * d, 0.0, 1.0)
        hl = np.exp(-np.hypot(vqx + 0.3, vqy - 0.35) * 6.0) * 0.4
        rgb = c * (0.7 + 0.8 * core)[..., None] + hl[..., None]
        a = a * (0.55 + 0.4 * core)

    elif typ == CRESCENT:
        d1 = np.hypot(qx, qy) - 0.9
        d2 = np.hypot(qx - 0.42, qy - 0.18) - 0.74
        d = np.maximum(d1, -d2)
        a = 1.0 - smoothstep(-e, e, d)
        g = np.clip(-d / 0.22, 0.0, 1.0)[..., None]
        rgb = (c * 0.7) * (1 - g) + (c * 1.2) * g
        a = a * 0.95

    else:   # BUBBLE
        d = lq
        ring = smoothstep(0.7, 0.97, d) * (1.0 - smoothstep(0.97, 1.03 + e, d))
        spot = np.exp(-np.hypot(vqx + 0.38, vqy - 0.4) * 9.0)
        a = np.clip(ring * 0.5 + spot * 0.9, 0.0, 1.0)
        rgb = np.array([0.9, 0.95, 1.0]) * ((ring * 0.6 + spot * 1.2) / np.maximum(a, 1e-3))[..., None]

    return rgb * depth_shade, a


def draw_parts(buf, parts, n, t, u_size=1.0):
    """buf (n,n,4 プリマルチプライド) に、手前から順ではなく渡された順で重ねる"""
    for p in parts:
        typ = int(p["type"])
        r = p["r"] * u_size * (0.85 + 0.3 * p["z"])
        pad = 2.6 if typ == GLITTER else 1.2
        half = r * pad                              # 四角形の半辺 (セル座標、半径1系)

        # セル座標 [-1,1] → 画素。画素中心は (i+0.5)/n*2-1
        x0 = int(np.floor((p["x"] - half + 1.0) * 0.5 * n))
        x1 = int(np.ceil((p["x"] + half + 1.0) * 0.5 * n))
        y0 = int(np.floor((p["y"] - half + 1.0) * 0.5 * n))
        y1 = int(np.ceil((p["y"] + half + 1.0) * 0.5 * n))
        x0, x1 = max(x0, 0), min(x1, n)
        y0, y1 = max(y0, 0), min(y1, n)
        if x0 >= x1 or y0 >= y1:
            continue

        ix, iy = np.meshgrid(np.arange(x0, x1), np.arange(y0, y1))
        sx = (ix + 0.5) / n * 2.0 - 1.0
        sy = (iy + 0.5) / n * 2.0 - 1.0
        vqx = (sx - p["x"]) / r                     # vQ = aCorner * pad の連続版
        vqy = (sy - p["y"]) / r

        ca, sa = np.cos(p["rot"]), np.sin(p["rot"])
        qx = ca * vqx - sa * vqy                    # rot(a) = mat2(c, s, -s, c)
        qy = sa * vqx + ca * vqy

        rgb, a = shade_piece(p, qx, qy, vqx, vqy, t)
        src = rgb * a[..., None] if typ != GLITTER else rgb
        inv = (1.0 - a)[..., None]
        sub = buf[y0:y1, x0:x1]
        sub[..., :3] = src + sub[..., :3] * inv
        sub[..., 3:4] = a[..., None] + sub[..., 3:4] * inv


def render_cell(parts, n, t, u_size=1.0):
    """renderCell() と同じ。奥層 (地 + z<0.5) と手前層 (z>=0.5) を返す"""
    s = sorted(parts, key=lambda p: p["z"])
    back_list = [p for p in s if p["z"] < 0.5]
    front_list = [p for p in s if p["z"] >= 0.5]

    back = oil_bg(n, t)
    draw_parts(back, back_list, n, t, u_size)

    front = np.zeros((n, n, 4))
    draw_parts(front, front_list, n, t, u_size)
    return back, front


def to_img(buf):
    """プリマルチプライドのまま PNG と同じ並びにする (WebGL の読み出しと同じ)"""
    return np.clip(buf, 0.0, 1.0)


def compare(name, mine, ref_path):
    ref = np.asarray(Image.open(ref_path).convert("RGBA"), dtype=np.float64) / 255.0
    # WebGL は左下原点、PNG は上から。吸い出しでどうなったかは突き合わせて確かめる
    best = None
    for flip, tag in ((False, "そのまま"), (True, "上下反転")):
        m = mine[::-1] if flip else mine
        d = np.abs(m - ref).mean() * 255.0
        if best is None or d < best[0]:
            best = (d, tag)
    print("  %-6s 平均の差 %6.2f / 255   (%s)" % (name, best[0], best[1]))
    return best


def main():
    t = 0.0
    if "--time" in sys.argv:
        t = float(sys.argv[sys.argv.index("--time") + 1])

    d = json.load(io.open(os.path.join(DUMP, "parts.json"), encoding="utf-8"))
    parts = d["parts"]
    ref_back = Image.open(os.path.join(DUMP, "cell_back.png"))
    n = ref_back.size[0]
    print("ピース %d 個、セル %dx%d、uTime = %.2f" % (len(parts), n, n, t))

    back, front = render_cell(parts, n, t)
    Image.fromarray((to_img(back) * 255).astype(np.uint8)).save("sim/mycell_back.png")
    Image.fromarray((to_img(front) * 255).astype(np.uint8)).save("sim/mycell_front.png")
    print("sim/mycell_back.png / sim/mycell_front.png に出した")

    compare("奥層", to_img(back), os.path.join(DUMP, "cell_back.png"))
    compare("手前層", to_img(front), os.path.join(DUMP, "cell_front.png"))


if __name__ == "__main__":
    main()
