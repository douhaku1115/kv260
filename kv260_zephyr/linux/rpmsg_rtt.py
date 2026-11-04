#!/usr/bin/env python3
# R5 の rpmsg-raw エコーと往復して時間を測る。R5_0 は "R5: "、R5_1 は "R5_1: " を付けて送り返す
#   使い方: sudo python3 rpmsg_rtt.py [回数] [バイト数] [コア 0|1]
#   コア 0 (既定) = R5_0 のエコー (番号 0x400)、1 = R5_1 のエコー (番号 0x401)
import glob
import os
import sys
import time

n = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
size = int(sys.argv[2]) if len(sys.argv) > 2 else 32
core = int(sys.argv[3]) if len(sys.argv) > 3 else 0
addr, prefix = (1024, b"R5: ") if core == 0 else (1025, b"R5_1: ")

dev = None
for d in glob.glob("/sys/class/rpmsg/rpmsg[0-9]*"):
    if os.path.realpath(d).endswith(f".rpmsg-raw.-1.{addr}/rpmsg/{os.path.basename(d)}"):
        dev = "/dev/" + os.path.basename(d)
if dev is None:
    sys.exit(f"R5_{core} のエコー (番号 {addr:#x}) がない。R5 は動いている? (r5_start.sh)")

fd = os.open(dev, os.O_RDWR)
bad = 0
rtts = []
for i in range(n):
    msg = (b"%08d" % i).ljust(size, b"x")[:size]
    t0 = time.perf_counter()
    os.write(fd, msg)
    res = os.read(fd, 512)
    rtts.append(time.perf_counter() - t0)
    if res != prefix + msg:
        bad += 1
os.close(fd)

rtts.sort()
us = [t * 1e6 for t in rtts]
print(f"R5_{core} ({dev}): {n} 往復 / {size} バイト / 不一致 {bad}")
print(f"最小 {us[0]:.0f} us  中央 {us[n // 2]:.0f} us  平均 {sum(us) / n:.0f} us  最大 {us[-1]:.0f} us")
