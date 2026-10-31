#!/usr/bin/env python3
# R5 に音を流させる (Linux は音源を DDR に置いて指示するだけ)。apps/rpmsg_r5/src/audio_rpmsg.c と対
#   sudo python3 r5play.py song.raw            キー操作で再生 (+/- 音量、e エコー、q 停止)
#   sudo python3 r5play.py song.raw 秒数       その秒数だけ鳴らして統計を出す (SSH からの実測用)
#   sudo python3 r5play.py --stop              止める
#
# 先に PL (kv260_i2s2 の stream 設計) を書いてクロックを入れておく:
#   sudo fpgautil -b stream_r5.bit
#   sudo devmem 0xFF5E00C0 32 0x01010A00
#
# 音源は段6以降の play.c / dmaplay と同じ生 PCM (ffmpeg -ac 2 -ar 48828 -f s16le -acodec pcm_s16le)。
# 1 語 (4 バイト) = 1 組。中身は並べ替えずにそのまま渡す。
# 置き場所の 0x60000000〜 (512MB) は起動引数 mem=1536M で Linux 管理外にしてある。
import glob
import mmap
import os
import select
import struct
import sys
import termios
import time
import tty

ADDR = 1056                 # 0x420 = 音声の窓口
DDR_PHYS, DDR_MAX = 0x60000000, 512 << 20
MAGIC_CMD, MAGIC_RES = 0x43445541, 0x52445541
RES_FMT = "<10I"            # magic status playing pos len level min_level n_empty n_tick fill_max_us
RATE = 48828.125            # 1 秒あたりの組数 (12.5MHz / 256)
STATUS_TXT = {0: "正常", 1: "PL が音声設計でない", 2: "形式違い/再生中"}

state = open("/sys/class/fpga_manager/fpga0/state").read().strip()
if state != "operating":
    sys.exit(f"PL が書き込まれていない (fpga0 state = {state})。fpgautil と devmem を先に")

dev = None
for d in glob.glob("/sys/class/rpmsg/rpmsg[0-9]*"):
    if os.path.realpath(d).endswith(f".rpmsg-raw.-1.{ADDR}/rpmsg/{os.path.basename(d)}"):
        dev = "/dev/" + os.path.basename(d)
if dev is None:
    sys.exit("音声の窓口 (rpmsg-raw, 0x420) がない。R5 は動いている? (r5_start.sh)")
fd = os.open(dev, os.O_RDWR)


def cmd(c, a=0, b=0):
    os.write(fd, struct.pack("<4I", MAGIC_CMD, c, a, b))
    r = struct.unpack(RES_FMT, os.read(fd, 512)[:struct.calcsize(RES_FMT)])
    if r[0] != MAGIC_RES:
        sys.exit(f"返事の形が違う magic={r[0]:#x}")
    return dict(zip(["magic", "status", "playing", "pos", "len", "level", "min_level", "n_empty",
                     "n_tick", "fill_max_us"], r))


def show(r, end="\n"):
    sec = r["pos"] / 4 / RATE
    print(f"\r{sec:7.1f} 秒  残量 {r['level']:4d}  最小 {r['min_level']:4d}  空 {r['n_empty']}回  "
          f"見回り {r['n_tick']}回  書き足し最長 {r['fill_max_us']} us   ", end=end, flush=True)


if len(sys.argv) > 1 and sys.argv[1] == "--stop":
    show(cmd(2))
    sys.exit(0)
if len(sys.argv) < 2:
    sys.exit(__doc__ if __doc__ else "使い方は先頭のコメントを参照")

# ---- 音源を PL 専用 DDR に置く ----
path = sys.argv[1]
size = os.path.getsize(path) & ~3
if size > DDR_MAX:
    sys.exit(f"音源が大きすぎる ({size} バイト > 512MB)")
t0 = time.perf_counter()
mfd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
buf = mmap.mmap(mfd, (size + 4095) & ~4095, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE,
                offset=DDR_PHYS)
with open(path, "rb") as f:
    off = 0
    while off < size:
        chunk = f.read(min(16 << 20, size - off))
        buf[off:off + len(chunk)] = chunk
        off += len(chunk)
buf.close()
os.close(mfd)
print(f"{path}: {size} バイト ({size / 4 / RATE:.0f} 秒分) を {DDR_PHYS:#x} に置いた "
      f"({time.perf_counter() - t0:.1f} 秒)")

r = cmd(1, DDR_PHYS, size)
if r["status"] != 0:
    sys.exit(f"再生できない: {STATUS_TXT.get(r['status'], r['status'])}")

# ---- 秒数指定: 黙って鳴らして統計だけ出す ----
if len(sys.argv) > 2:
    end = time.time() + float(sys.argv[2])
    while time.time() < end:
        time.sleep(1)
        show(cmd(5), end="")
    print()
    show(cmd(2))
    sys.exit(0)

# ---- キー操作 ----
gain, echo = 64, 0
print("+/- 音量  e エコー  r 統計を消す  q 停止")
old = termios.tcgetattr(0)
tty.setcbreak(0)
try:
    while True:
        if select.select([0], [], [], 0.5)[0]:
            k = sys.stdin.read(1)
            if k == "q":
                break
            if k in "+-":
                gain = max(0, min(255, gain + (16 if k == "+" else -16)))
                cmd(3, gain)
            elif k == "e":
                echo = 0 if echo else 0x80
                cmd(4, echo)
            elif k == "r":
                cmd(6)
        r = cmd(5)
        show(r, end="")
        if not r["playing"]:
            break
finally:
    termios.tcsetattr(0, termios.TCSADRAIN, old)
print()
show(cmd(2))
