#!/usr/bin/env python3
# R5 で音を作らせる (音源ファイルなし)。apps/rpmsg_r5/src/synth.c と audio_rpmsg.c (命令 8〜12) と対
#   sudo python3 r5synth.py                 キー演奏 (下の表)
#   sudo python3 r5synth.py twinkle         きらきら星を R5 の時計で演奏 (段3 と同じ音の並び + 低音)
#   sudo python3 r5synth.py notes 30        30 秒間 0.1 秒ごとに音を頼み、遅れと途切れを測る (SSH からの実測用)
#   最後の引数に数字を足すと FIFO の上限 (段)。既定 256 (約 5.2ms 分)
#
# 先に PL (kv260_i2s2 の stream 設計) を書いてクロックを入れておく:
#   sudo fpgautil -b stream.bit
#   sudo devmem 0xFF5E00C0 32 0x01010A00
import glob
import os
import random
import select
import struct
import sys
import termios
import time
import tty

ADDR = 1056                 # 0x420 = 音声の窓口 (再生と同じ窓口に命令 8〜12 を足した)
MAGIC_CMD, MAGIC_RES = 0x43445541, 0x52445541
NAMES = ["magic", "status", "playing", "pos", "len", "level", "min_level", "n_empty", "n_tick",
         "fill_max_us", "synth_on", "n_notes", "n_lat", "lat_max_us", "lat_avg_us", "active", "score_run"]
RES_FMT = f"<{len(NAMES)}I"
WAVES = ["正弦", "矩形", "のこぎり", "三角"]

# キー → ドからの半音数 (ピアノの並び。a=ド w=ド# s=レ ...)
KEYS = {"a": 0, "w": 1, "s": 2, "e": 3, "d": 4, "f": 5, "t": 6, "g": 7, "y": 8, "h": 9, "u": 10,
        "j": 11, "k": 12, "o": 13, "l": 14}

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
    r = dict(zip(NAMES, struct.unpack(RES_FMT, os.read(fd, 512)[:struct.calcsize(RES_FMT)])))
    if r["magic"] != MAGIC_RES:
        sys.exit(f"返事の形が違う magic={r['magic']:#x}")
    return r


def note(n, len_ms=300, vel=100):
    return cmd(9, n, len_ms | vel << 16)


def stats(r):
    return (f"音 {r['n_notes']}  遅れ 平均 {r['lat_avg_us']} us 最長 {r['lat_max_us']} us ({r['n_lat']} 回)  "
            f"残量 最小 {r['min_level']}  空 {r['n_empty']}回  1ms の処理 最長 {r['fill_max_us']} us")


# 引数: [keys|twinkle] [上限]  または  notes [秒] [上限]
args = sys.argv[1:]
mode = args.pop(0) if args and not args[0].isdigit() else "keys"
dur = float(args.pop(0)) if mode == "notes" and args else 30
limit = int(args[0]) if args else 256

if cmd(7, limit)["status"] != 0:
    sys.exit(f"上限 {limit} は範囲外 (1〜8192)")
r = cmd(8, 1)
if r["status"] != 0:
    sys.exit({1: "PL が音声設計でない", 2: "再生中 (先に r5play.py --stop)"}.get(r["status"], r))
print(f"シンセ開始 (FIFO の上限 {limit} 段 = {limit / 48.828:.1f} ms 分)")

try:
    if mode == "twinkle":
        # きらきら星 (段3 と同じ並び)。4 分音符 = 400ms。1 小節ごとに低音 (1 オクターブ下の根音) を足す
        mel = [60, 60, 67, 67, 69, 69, 67, 0, 65, 65, 64, 64, 62, 62, 60, 0,
               67, 67, 65, 65, 64, 64, 62, 0, 67, 67, 65, 65, 64, 64, 62, 0,
               60, 60, 67, 67, 69, 69, 67, 0, 65, 65, 64, 64, 62, 62, 60, 0]
        bass = [48, 53, 48, 43, 48, 43, 48, 43, 48, 53, 48, 43]   # 半小節 (800ms) ごと
        q = 400
        cmd(12, 0)
        for i, n in enumerate(mel):
            if n:
                hold = 2 if i + 1 < len(mel) and mel[i + 1] == 0 else 1   # 次が休みなら 2 拍
                cmd(11, i * q, n | 100 << 8 | (q * hold - 40) << 16)
        for i, n in enumerate(bass):
            cmd(11, i * 2 * q, n | 70 << 8 | (2 * q - 40) << 16)
        cmd(10, 3)   # 三角波
        r = cmd(12, 1)
        if r["status"] != 0:
            sys.exit(f"楽譜を始められない status={r['status']} (楽譜は最大 256 音)")
        while cmd(5)["score_run"]:
            time.sleep(0.2)
    elif mode == "notes":
        # 実測用: 0.1 秒ごとに 1 音頼む (高さはランダム)。遅れ = 命令を受けてから音が出るまで
        end = time.time() + dur
        while time.time() < end:
            note(random.randint(55, 79), 150, 90)
            time.sleep(0.1)
        time.sleep(0.3)
    else:
        base, w = 60, 0
        print("白鍵 a s d f g h j k l / 黒鍵 w e t y u o   z/x オクターブ  1〜4 波形  q 終わり")
        old = termios.tcgetattr(0)
        tty.setcbreak(0)
        try:
            while True:
                if not select.select([0], [], [], 0.5)[0]:
                    continue
                k = sys.stdin.read(1)
                if k == "q":
                    break
                if k in KEYS:
                    note(base + KEYS[k], 350, 100)
                elif k in "zx":
                    base = max(24, min(96, base + (-12 if k == "z" else 12)))
                    print(f"\rオクターブ: ド = {base}      ", end="", flush=True)
                elif k in "1234":
                    w = int(k) - 1
                    cmd(10, w)
                    print(f"\r波形: {WAVES[w]}        ", end="", flush=True)
        finally:
            termios.tcsetattr(0, termios.TCSADRAIN, old)
        print()
finally:
    r = cmd(8, 0)   # 止める (残りを鳴らし切る)
    print(stats(r))
