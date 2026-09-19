# -*- coding: utf-8 -*-
"""シミュレーションが吐いた frame.txt を PNG にする。

  使い方:  python tools/txt2png.py simbuild/frame.txt sim/rtl_scope.png
"""
import sys
import numpy as np
from PIL import Image

W, H = 1280, 720

src = sys.argv[1] if len(sys.argv) > 1 else "simbuild/frame.txt"
dst = sys.argv[2] if len(sys.argv) > 2 else "sim/rtl_scope.png"

buf = np.fromfile(src, dtype=np.uint8)
# 1 行 = "rrggbb" + 改行。Windows では CRLF になるので 8 バイト
stride = 8 if (buf.size % 8 == 0 and buf[6] == 13) else 7
hexs = buf.reshape(-1, stride)[:, :6].tobytes().decode("ascii")
rgb = np.array([int(hexs[i:i + 6], 16) for i in range(0, len(hexs), 6)], dtype=np.uint32)

n = rgb.size
print("%d 画素 (期待 %d)" % (n, W * H))
if n < W * H:
    rgb = np.concatenate([rgb, np.zeros(W * H - n, dtype=np.uint32)])
rgb = rgb[:W * H]

img = np.stack([(rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF], -1).astype(np.uint8)
Image.fromarray(img.reshape(H, W, 3)).save(dst)
print("wrote", dst)
