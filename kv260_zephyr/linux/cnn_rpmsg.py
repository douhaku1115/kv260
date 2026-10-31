#!/usr/bin/env python3
# R5 の Zephyr に RPMsg で CNN の推論を頼み、答えとスコアを期待値と照合して時間を測る
#   sudo python3 cnn_rpmsg.py [回数] [test_images.hex] [test_scores.hex]
#
# 先に PL を書いてクロックを入れておく (R5 は空の PL に触ると止まるおそれがある):
#   sudo fpgautil -b design_1_wrapper.bit
#   sudo devmem 0xFF5E00C0 32 0x01010A00
#
# メッセージの形は apps/rpmsg_r5/src/cnn_rpmsg.c の冒頭を参照。
# テスト画像と期待値は kv260_cnn/sim/test_images.hex (1 行 1 画素) と test_scores.hex (1 行 1 スコア)。
import glob
import os
import struct
import sys
import time

ADDR = 1040          # 0x410 = CNN の窓口
XLEN, NOUT, NIMG = 784, 10, 10
CHUNK = 392          # RPMsg の 1 通は最大 496 バイト。画像を 2 通に分ける
MAGIC_REQ, MAGIC_RES = 0x494E4E43, 0x524E4E43
RES_FMT = "<5I10i"   # magic seq status digit run_us score[10]

n = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
img_file = sys.argv[2] if len(sys.argv) > 2 else "test_images.hex"
sc_file = sys.argv[3] if len(sys.argv) > 3 else "test_scores.hex"

# ---- PL が書き込み済みか (空の PL だと R5 が止まるおそれ) ----
state = open("/sys/class/fpga_manager/fpga0/state").read().strip()
if state != "operating":
    sys.exit(f"PL が書き込まれていない (fpga0 state = {state})。fpgautil と devmem を先に")

# ---- CNN の窓口 (/dev/rpmsgN) を番号で探す ----
dev = None
for d in glob.glob("/sys/class/rpmsg/rpmsg[0-9]*"):
    if os.path.realpath(d).endswith(f".rpmsg-raw.-1.{ADDR}/rpmsg/{os.path.basename(d)}"):
        dev = "/dev/" + os.path.basename(d)
if dev is None:
    sys.exit("CNN の窓口 (rpmsg-raw, 0x410) がない。R5 は動いている? (r5_start.sh)")

images = bytes(int(x, 16) for x in open(img_file).read().split())
scores = [struct.unpack("<i", struct.pack("<I", int(x, 16)))[0] for x in open(sc_file).read().split()]
assert len(images) == XLEN * NIMG and len(scores) == NOUT * NIMG


def expected_digit(k):
    s = scores[k * NOUT:(k + 1) * NOUT]
    return s.index(max(s))   # 同点は先勝ち (numpy.argmax と同じ)


fd = os.open(dev, os.O_RDWR)
bad = status_err = 0
rtts, runs = [], []
t_start = time.perf_counter()
for seq in range(1, n + 1):
    k = seq % NIMG
    img = images[k * XLEN:(k + 1) * XLEN]
    t0 = time.perf_counter()
    for off in range(0, XLEN, CHUNK):
        part = img[off:off + CHUNK]
        os.write(fd, struct.pack("<IIHH", MAGIC_REQ, seq, off, len(part)) + part)
    res = os.read(fd, 512)
    rtts.append(time.perf_counter() - t0)

    magic, rseq, status, digit, run_us, *sc = struct.unpack(RES_FMT, res[:struct.calcsize(RES_FMT)])
    if magic != MAGIC_RES or rseq != seq or status != 0:
        status_err += 1
        if status_err <= 3:
            print(f"返事の異常: seq={seq} magic={magic:#x} rseq={rseq} status={status}")
        continue
    runs.append(run_us)
    if digit != expected_digit(k) or sc != scores[k * NOUT:(k + 1) * NOUT]:
        bad += 1
elapsed = time.perf_counter() - t_start
os.close(fd)

us = sorted(t * 1e6 for t in rtts)
print(f"{dev}: {n} 枚 / 不一致 {bad} / 返事の異常 {status_err} / {n / elapsed:.0f} 枚/秒")
print(f"往復 最小 {us[0]:.0f} us  中央 {us[n // 2]:.0f} us  平均 {sum(us) / n:.0f} us  最大 {us[-1]:.0f} us")
if runs:
    print(f"R5 で測った PL の推論 (休みながら待つ分を含む) 平均 {sum(runs) / len(runs):.0f} us")
