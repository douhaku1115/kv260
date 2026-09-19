# -*- coding: utf-8 -*-
"""RTL の出力と、参照実装 (WebGL) の出力を画素単位で突き合わせる。

参照実装から取り出したセル画像をそのまま PL に焼き込んであるので、
同じ入力に対する同じ計算の結果を比べられる。自作モデル同士の比較より強い。

  ref/dump/scope_ref.png   WebGL の出力 (1280x720、そのセル画像で描いたもの)
  simbuild/frame.txt       RTL の出力

差が出る原因として、実装差が3つ分かっている:
  1. 奥層/手前層の2層合成 (CELL_GAP の視差と影) が RTL では未実装
  2. セル画像が 1024 → 256 に縮んでいる
  3. ミップマップ/LOD、オイルの揺らぎ、色収差、ディザ が RTL では未実装

  使い方:  python tools/cmp_webgl.py
"""
import sys
import numpy as np
from PIL import Image

W, H = 1280, 720


def load_rtl(path="simbuild/frame.txt"):
    buf = np.fromfile(path, dtype=np.uint8)
    stride = 8 if (buf.size % 8 == 0 and buf[6] == 13) else 7
    hexs = buf.reshape(-1, stride)[:, :6].tobytes().decode("ascii")
    v = np.array([int(hexs[i:i+6], 16) for i in range(0, len(hexs), 6)], dtype=np.uint32)
    if v.size < W * H:
        v = np.concatenate([v, np.zeros(W * H - v.size, dtype=np.uint32)])
    v = v[:W * H]
    return np.stack([(v >> 16) & 255, (v >> 8) & 255, v & 255], -1).astype(np.uint8).reshape(H, W, 3)


if __name__ == "__main__":
    rtl = load_rtl(sys.argv[1] if len(sys.argv) > 1 else "simbuild/frame.txt")
    ref = np.asarray(Image.open("ref/dump/scope_ref.png").convert("RGB"), dtype=np.uint8)

    # WebGL の readPixels は下から上。PNG も同じ並びで保存してあるので上下を合わせる
    ref = ref[::-1]

    Image.fromarray(rtl).save("sim/rtl_realcell.png")
    Image.fromarray(ref).save("sim/webgl_ref.png")

    d = np.abs(rtl.astype(np.int32) - ref.astype(np.int32))
    print("平均差 %.2f/255   中央値 %.0f   16/255超の画素 %.2f%%   32/255超 %.2f%%"
          % (d.mean(), np.median(d), 100*(d.max(-1) > 16).mean(), 100*(d.max(-1) > 32).mean()))

    vis = rtl.copy()
    vis[d.max(-1) > 32] = [255, 0, 0]
    Image.fromarray(vis).save("sim/diff_webgl.png")
    print("wrote sim/rtl_realcell.png  sim/webgl_ref.png  sim/diff_webgl.png")

    # 左半分 RTL / 右半分 WebGL の並べ画像
    side = ref.copy()
    side[:, :W//2] = rtl[:, :W//2]
    side[:, W//2-1:W//2+1] = [255, 255, 0]
    Image.fromarray(side).save("sim/side_by_side.png")
    print("wrote sim/side_by_side.png  (左=RTL / 右=WebGL)")
