# -*- coding: utf-8 -*-
"""
raw2hex.py -- 16ビット符号付きPCM(生データ)を Verilog の $readmemh 用hexに変換

  入力 : clip.raw   (16ビット符号付き little-endian, 単音)
  出力 : audio_rom.hex  (1行1標本, 4桁16進, 2の補数表現)
         音量調整も行う(過大なら割る)
"""
import struct
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.join(HERE, "clip.raw")
DST  = os.path.join(HERE, "audio_rom.hex")

# 音量倍率(1.0で原音のまま。元音源が小さいので増幅する)
GAIN = 8.0

with open(SRC, "rb") as f:
    data = f.read()

n = len(data) // 2
samples = struct.unpack("<%dh" % n, data[:n*2])

peak = max(abs(s) for s in samples) if samples else 0
print("標本数      : %d" % n)
print("再生時間    : %.2f 秒 (48828Hz)" % (n / 48828.0))
print("最大振幅    : %d (16ビット上限 32767)" % peak)
print("必要メモリ  : %.2f Mbit" % (n * 16 / 1e6))

with open(DST, "w") as f:
    for s in samples:
        v = int(s * GAIN)
        if v >  32767: v =  32767
        if v < -32768: v = -32768
        f.write("%04X\n" % (v & 0xFFFF))   # 2の補数を4桁16進で

print("出力        : %s" % DST)
print("完了")
