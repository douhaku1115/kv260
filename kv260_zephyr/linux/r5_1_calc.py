#!/usr/bin/env python3
# R5_1 (2 コア目) に重い計算 (n 以下の素数を割り算で数える) を頼む。apps/rpmsg_r5_1 の 0x450 窓口と対
#   sudo python3 r5_1_calc.py [n]          1 回だけ頼み、答えと時間を表示 (既定 n = 200000)
#   sudo python3 r5_1_calc.py [n] [秒]     その秒数のあいだ続けて頼み、R5_1 をほぼ 100% 働かせる
#                                          (R5_0 の音が乱れないかを同時に測るため)
import glob
import os
import struct
import sys
import time

ADDR = 1104                 # 0x450
MAGIC_REQ, MAGIC_RES = 0x434C4143, 0x524C4143

n = int(sys.argv[1]) if len(sys.argv) > 1 else 200000
dur = float(sys.argv[2]) if len(sys.argv) > 2 else 0

dev = None
for d in glob.glob("/sys/class/rpmsg/rpmsg[0-9]*"):
    if os.path.realpath(d).endswith(f".rpmsg-raw.-1.{ADDR}/rpmsg/{os.path.basename(d)}"):
        dev = "/dev/" + os.path.basename(d)
if dev is None:
    sys.exit("R5_1 の計算役 (rpmsg-raw, 0x450) がない。R5_1 は動いている? (r5_start.sh)")

fd = os.open(dev, os.O_RDWR)
seq, busy_us, counts = 0, 0, set()
t0 = time.perf_counter()
while True:
    seq += 1
    os.write(fd, struct.pack("<3I", MAGIC_REQ, seq, n))
    magic, rseq, rn, count, us = struct.unpack("<5I", os.read(fd, 512)[:20])
    if magic != MAGIC_RES or rseq != seq or rn != n:
        sys.exit(f"返事の形が違う magic={magic:#x} seq={rseq}/{seq}")
    busy_us += us
    counts.add(count)
    if time.perf_counter() - t0 >= dur:
        break
el = time.perf_counter() - t0
os.close(fd)
print(f"R5_1: {n} 以下の素数 {sorted(counts)} 個 / {seq} 回 / 1 回 {busy_us / seq / 1000:.1f} ms / "
      f"R5_1 が計算していた割合 {busy_us / 1e6 / el * 100:.1f}% ({el:.1f} 秒中)")
