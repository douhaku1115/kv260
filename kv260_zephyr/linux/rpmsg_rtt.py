#!/usr/bin/env python3
# /dev/rpmsg0 (R5 の rpmsg-raw) と往復して時間を測る。R5 は "R5: " を付けて送り返す
#   使い方: sudo python3 rpmsg_rtt.py [回数] [バイト数]
import os
import sys
import time

n = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
size = int(sys.argv[2]) if len(sys.argv) > 2 else 32

fd = os.open("/dev/rpmsg0", os.O_RDWR)
bad = 0
rtts = []
for i in range(n):
    msg = (b"%08d" % i).ljust(size, b"x")[:size]
    t0 = time.perf_counter()
    os.write(fd, msg)
    res = os.read(fd, 512)
    rtts.append(time.perf_counter() - t0)
    if res != b"R5: " + msg:
        bad += 1
os.close(fd)

rtts.sort()
us = [t * 1e6 for t in rtts]
print(f"{n} 往復 / {size} バイト / 不一致 {bad}")
print(f"最小 {us[0]:.0f} us  中央 {us[n // 2]:.0f} us  平均 {sum(us) / n:.0f} us  最大 {us[-1]:.0f} us")
