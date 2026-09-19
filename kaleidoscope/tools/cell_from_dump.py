# -*- coding: utf-8 -*-
"""参照実装から取り出したセル画像を、PL の cell_mem 用 .hex にする。

  ref/dump/cell_back.png   奥層 (不透明)
  ref/dump/cell_front.png  手前層 (プリマルチプライドα)

出力 (段5a の2層合成用):
  rtl/cell_back.hex    RGB565            16bit
  rtl/cell_front.hex   32bit  {ablur[7:0], a[7:0], rgb565[15:0]}

    ablur は影用にぼかした α。参照実装は手前層の α を (0.012,-0.016) ずらし、
    さらに lod+2 相当にぼかして奥層に影を落とす。そのぼかしをここで前計算
    しておくと、PL 側にぼかす回路が要らない。24bit でも 32bit でも
    BRAM の消費は同じ (18bit 単位で2枚) なので、詰め込んで損はない。

参考として1枚に合成したものも出す (段2〜4 で使っていた形):
  rtl/cell_real.hex    RGB565            16bit

PL が焼き込むのは rtl/cell_init.hex (1層版) と
rtl/cell_back_init.hex / rtl/cell_front_init.hex (2層版)。
使いたい方をコピーすること。

  使い方:  python tools/cell_from_dump.py [一辺]
"""
import sys
import numpy as np
from PIL import Image
from scipy.ndimage import uniform_filter

N = int(sys.argv[1]) if len(sys.argv) > 1 else 256
SRC = "ref/dump"


def load(name):
    return np.asarray(Image.open("%s/%s.png" % (SRC, name)).convert("RGBA"),
                      dtype=np.float64) / 255.0


def shrink(a, n):
    k = a.shape[0] // n
    return a.reshape(n, k, n, k, a.shape[2]).mean(axis=(1, 3))


def rgb565(img):
    r = np.clip(np.rint(img[..., 0] * 31), 0, 31).astype(np.int64)
    g = np.clip(np.rint(img[..., 1] * 63), 0, 63).astype(np.int64)
    b = np.clip(np.rint(img[..., 2] * 31), 0, 31).astype(np.int64)
    return (r << 11) | (g << 5) | b


def write_hex(path, vals, digits):
    with open(path, "w") as f:
        f.write("\n".join(("%0" + str(digits) + "x") % x for x in vals.ravel()) + "\n")
    print("wrote %s  (%d エントリ)" % (path, vals.size))


def main():
    back = load("cell_back")
    front = load("cell_front")
    print("元の大きさ %dx%d → %dx%d に縮小" % (back.shape[1], back.shape[0], N, N))

    b = shrink(back, N)
    f = shrink(front, N)

    # ---- 2層版 ----
    write_hex("rtl/cell_back.hex", rgb565(b), 4)

    fa = np.clip(np.rint(f[..., 3] * 255), 0, 255).astype(np.int64)
    # 影用のぼかし α。参照実装の lod+2 相当 (1024 で 8 texel = 256 で 2 texel)
    fb = uniform_filter(f[..., 3], size=max(2, 8 * N // 1024))
    fb = np.clip(np.rint(fb * 255), 0, 255).astype(np.int64)
    write_hex("rtl/cell_front.hex", (fb << 24) | (fa << 16) | rgb565(f), 8)

    # ---- 1層に合成したもの (段2〜4 で使っていた形) ----
    #   手前層はプリマルチプライドαなので  out = F.rgb + B.rgb*(1-F.a)
    comp = np.clip(f[..., :3] + b[..., :3] * (1.0 - f[..., 3:4]), 0, 1)
    write_hex("rtl/cell_real.hex", rgb565(comp), 4)

    Image.fromarray((comp * 255 + 0.5).astype(np.uint8)).save("sim/cell_%d.png" % N)
    print("wrote sim/cell_%d.png  (合成したもの、目視用)" % N)
    print()
    print("PL に焼くときは使いたい方をコピーする:")
    print("  1層版: cp rtl/cell_real.hex  rtl/cell_init.hex")
    print("  2層版: cp rtl/cell_back.hex  rtl/cell_back_init.hex")
    print("         cp rtl/cell_front.hex rtl/cell_front_init.hex")


if __name__ == "__main__":
    main()
