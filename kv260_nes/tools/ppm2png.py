"""テキスト PPM (P3) を PNG にする。標準ライブラリだけで書く。

  python tools/ppm2png.py 入力.ppm 出力.png [倍率]
倍率 (既定 2) で縦横を整数倍に拡大する (画素がつぶれないように最近傍)。
"""
import struct
import sys
import zlib

src, dst = sys.argv[1], sys.argv[2]
scale = int(sys.argv[3]) if len(sys.argv) > 3 else 2

tok = []
for line in open(src):
    line = line.split("#")[0]
    tok += line.split()
if tok[0] != "P3":
    sys.exit("P3 ではない")
w, h, mx = int(tok[1]), int(tok[2]), int(tok[3])
vals = list(map(int, tok[4:4 + w * h * 3]))

rows = []
for y in range(h):
    row = bytearray()
    for x in range(w):
        r, g, b = vals[(y * w + x) * 3:(y * w + x) * 3 + 3]
        row += bytes((r, g, b)) * scale
    for _ in range(scale):
        rows.append(b"\x00" + bytes(row))


def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", w * scale, h * scale, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
png += chunk(b"IEND", b"")
open(dst, "wb").write(png)
print(f"{dst}: {w * scale}x{h * scale}")
