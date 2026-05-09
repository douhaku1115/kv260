#!/usr/bin/env python3
# bin2array.py — フラットバイナリを uint32 C配列に変換する
#
# 使い方: python3 bin2array.py test10.bin
# 出力:   test10_program[] の定義（main.c に貼り付け用）

import sys
import struct

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 bin2array.py <binary>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1], 'rb') as f:
        data = f.read()

    # 4バイト境界にパディング
    while len(data) % 4 != 0:
        data += b'\x00'

    words = []
    for i in range(0, len(data), 4):
        word = struct.unpack('>I', data[i:i+4])[0]
        words.append(word)

    print("static const u32 test10_program[] = {")
    for i, w in enumerate(words):
        print(f"    0x{w:08X},  // [{i:3d}] 0x{i*4:04X}")
    print("};")
    print(f"#define TEST10_COUNT  (sizeof(test10_program) / sizeof(test10_program[0]))")

if __name__ == '__main__':
    main()
