# -*- coding: utf-8 -*-
"""kv260_cnn/sim のテスト画像と期待スコアを C のヘッダにする (Zephyr にはファイルが無いので埋め込む)。

使い方: python gen_cnn_data.py <test_images.hex> <test_scores.hex> <出力 .h>
hex は 1 行 1 語。画像 10 枚 x 784 画素 (uint8)、スコア 10 枚 x 10 個 (int32 の 2 の補数)。
"""
import sys

NIMG, XLEN, NOUT = 10, 784, 10


def read_hex(path, n):
    words = [int(s, 16) for s in open(path, encoding="ascii").read().split()]
    if len(words) != n:
        sys.exit("%s: %d 語 (%d 語必要)" % (path, len(words), n))
    return words


img = read_hex(sys.argv[1], NIMG * XLEN)
scr = read_hex(sys.argv[2], NIMG * NOUT)
with open(sys.argv[3], "w", encoding="utf-8", newline="\n") as f:
    f.write("/* gen_cnn_data.py で生成。手で直さない */\n#pragma once\n#include <stdint.h>\n\n")
    f.write("#define NIMG %d\n#define XLEN %d\n#define NOUT %d\n\n" % (NIMG, XLEN, NOUT))
    f.write("static const uint8_t test_images[NIMG * XLEN] = {\n")
    for i in range(0, len(img), 28):
        f.write("\t" + ", ".join("%d" % (v & 0xFF) for v in img[i:i + 28]) + ",\n")
    f.write("};\n\nstatic const uint32_t test_scores[NIMG * NOUT] = {\n")
    for i in range(0, len(scr), NOUT):
        f.write("\t" + ", ".join("0x%08x" % v for v in scr[i:i + NOUT]) + ",\n")
    f.write("};\n")
print("  %s: 画像 %d 枚, スコア %d 個" % (sys.argv[3], NIMG, len(scr)))
