# -*- coding: utf-8 -*-
"""RTL シミュレーションの出力と、固定小数点モデルの出力を突き合わせる。

  使い方:  python tools/cmp_rtl.py [frame.txt]

  Verilog と同じ条件 (セル 256x256 を RGB565 に量子化、減光 LOSS^n、周辺減光)
  でモデルを回し、画素ごとの差を出す。差が大きければ Verilog のどこかが違う。
"""
import sys
import numpy as np
from PIL import Image
sys.path.insert(0, "tools")
import ref_scope as R

R.CELL_N = 256                       # Verilog の cell_mem と同じ大きさ
import fx_scope as F                 # noqa: E402  (CELL_N を変えてから読む)

W, H = R.W, R.H
src = sys.argv[1] if len(sys.argv) > 1 else "simbuild/frame.txt"


def load_rtl(path):
    buf = np.fromfile(path, dtype=np.uint8)
    # 1 行 = "rrggbb" + 改行。Windows だと CRLF で 8 バイトになる
    stride = 8 if (buf.size % 8 == 0 and buf[6] == 13) else 7
    raw = buf.reshape(-1, stride)[:, :6]
    hexs = raw.tobytes().decode("ascii")
    v = np.array([int(hexs[i:i+6], 16) for i in range(0, len(hexs), 6)], dtype=np.uint32)
    n = v.size
    if n < W * H:
        v = np.concatenate([v, np.zeros(W * H - n, dtype=np.uint32)])
    v = v[:W * H]
    return np.stack([(v >> 16) & 255, (v >> 8) & 255, v & 255], -1).astype(np.uint8).reshape(H, W, 3), n


def model():
    """fx_scope と同じ計算だが、色は Verilog に合わせて 8bit 整数で組み立てる。"""
    img_f, nrefl = F.render(16)      # 色以外 (座標と反射回数) はこれで得る
    return img_f, nrefl


if __name__ == "__main__":
    rtl, npix = load_rtl(src)
    print("RTL 画素数 %d (期待 %d)" % (npix, W * H))
    Image.fromarray(rtl).save("sim/rtl_scope.png")
    print("wrote sim/rtl_scope.png")

    mdl, _ = model()
    mdl8 = (mdl * 255 + 0.5).astype(np.uint8)
    Image.fromarray(mdl8).save("sim/model_cell256.png")
    print("wrote sim/model_cell256.png")

    d = np.abs(rtl.astype(np.int32) - mdl8.astype(np.int32))
    print("平均差 %.2f/255   最大 %d/255   16/255超の画素 %.2f%%"
          % (d.mean(), d.max(), 100 * (d.max(-1) > 16).mean()))

    # 差の大きいところを赤く塗った画像も出す
    bad = (d.max(-1) > 16)
    vis = rtl.copy()
    vis[bad] = [255, 0, 0]
    Image.fromarray(vis).save("sim/diff.png")
    print("wrote sim/diff.png  (差が大きい画素を赤で表示)")
