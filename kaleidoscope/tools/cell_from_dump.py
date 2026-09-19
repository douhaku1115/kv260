# -*- coding: utf-8 -*-
"""参照実装から取り出したセル画像を、PL の cell_mem 用 .hex にする。

ref/dump/cell_back.png   奥層 (不透明)
ref/dump/cell_front.png  手前層 (プリマルチプライドα)

段5 で2層合成を入れるまでは、ここで1枚に合成してから使う:
    out = front.rgb + back.rgb * (1 - front.a)

  使い方:  python tools/cell_from_dump.py [一辺]
"""
import sys
import numpy as np
from PIL import Image

N = int(sys.argv[1]) if len(sys.argv) > 1 else 256
SRC = "ref/dump"


def load(name):
    a = np.asarray(Image.open("%s/%s.png" % (SRC, name)).convert("RGBA"), dtype=np.float64) / 255.0
    return a


def main():
    back = load("cell_back")
    front = load("cell_front")
    print("元の大きさ %dx%d" % (back.shape[1], back.shape[0]))

    # 手前層はプリマルチプライドαで描かれている
    comp = front[..., :3] + back[..., :3] * (1.0 - front[..., 3:4])
    comp = np.clip(comp, 0.0, 1.0)

    # 面積平均で縮小
    src = back.shape[0]
    k = src // N
    small = comp.reshape(N, k, N, k, 3).mean(axis=(1, 3))

    Image.fromarray((small * 255 + 0.5).astype(np.uint8)).save("sim/cell_%d.png" % N)
    print("wrote sim/cell_%d.png" % N)

    r = np.clip(np.rint(small[..., 0] * 31), 0, 31).astype(np.int32)
    g = np.clip(np.rint(small[..., 1] * 63), 0, 63).astype(np.int32)
    b = np.clip(np.rint(small[..., 2] * 31), 0, 31).astype(np.int32)
    v = (r << 11) | (g << 5) | b

    with open("rtl/cell_real.hex", "w") as f:
        f.write("\n".join("%04x" % x for x in v.ravel()) + "\n")
    print("wrote rtl/cell_real.hex  (%dx%d RGB565)" % (N, N))
    print("  → 使うときは rtl/cell_init.hex にコピーする")


if __name__ == "__main__":
    main()
