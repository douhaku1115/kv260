#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# check_raw.py -- rtl_fm が出した生の音声(16bit モノラル)を調べる
#
#   プチプチ音の正体を切り分けるための道具。
#   rtl_fm の出力そのものにインパルス(急激な段差)が入っているかを数える。
#
#   使い方:
#     sudo timeout 10 rtl_fm -f 84.2M -M wbfm -s 244140 -r 48828 - 2>/dev/null > fm.raw
#     python3 check_raw.py fm.raw
# ---------------------------------------------------------------------------
import struct
import sys

path = sys.argv[1] if len(sys.argv) >= 2 else "fm.raw"
data = open(path, "rb").read()
n = len(data) // 2
s = struct.unpack("<%dh" % n, data[:n * 2])

# 隣り合う標本の差が大きい所＝インパルス（プチッと鳴る所）
TH = 16000
jump = [i for i in range(1, n) if abs(s[i] - s[i - 1]) > TH]

peak = max(abs(v) for v in s)
clip = sum(1 for v in s if abs(v) >= 32700)

print("ファイル      : %s" % path)
print("総標本数      : %d  (%.2f 秒 @48828Hz)" % (n, n / 48828.0))
print("最大振幅      : %d  (32767 が上限)" % peak)
print("飽和した標本  : %d 個" % clip)
print("急変(>%d)  : %d 個" % (TH, len(jump)))
print("最初の10箇所  : %s" % jump[:10])
if jump:
    print("1秒あたり     : %.1f 回" % (len(jump) / (n / 48828.0)))
