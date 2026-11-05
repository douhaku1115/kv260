#!/usr/bin/env python3
# R5 で音を作らせる (音源ファイルなし)。apps/rpmsg_r5/src/synth.c と audio_rpmsg.c (命令 8〜12) と対
#   sudo python3 r5synth.py                 キー演奏 (下の表)
#   sudo python3 r5synth.py twinkle         きらきら星を R5 の時計で演奏 (段3 と同じ音の並び + 低音)
#   sudo python3 r5synth.py notes 30        30 秒間 0.1 秒ごとに音を頼み、遅れと途切れを測る (SSH からの実測用)
#   最後の引数に数字を足すと FIFO の上限 (段)。既定 256 (約 5.2ms 分)
#   --r51 を付けると分業: 音は R5_1 が作ってリバーブを掛け (r51_audio.c)、R5_0 は流すだけ (命令 13)
#   --rev N でリバーブの量 (0 = 無し、既定 64)。キー演奏では r で 0 → 64 → 128 と切り替え
#
# 先に PL (kv260_i2s2 の stream 設計) を書いてクロックを入れておく:
#   sudo fpgautil -b stream.bit
#   sudo devmem 0xFF5E00C0 32 0x01010A00
import glob
import mmap
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
         "fill_max_us", "synth_on", "n_notes", "n_lat", "lat_max_us", "lat_avg_us", "active", "score_run",
         "ring_on", "n_ring_short"]
RES_FMT = f"<{len(NAMES)}I"
ADDR1 = 1120                # 0x460 = R5_1 の音の分業の窓口
NAMES1 = ["magic", "status", "n_notes", "n_lat", "lat_max_us", "lat_avg_us", "active", "score_run",
          "gen_max_us", "gen_avg_us", "n_kick", "reverb"]
RES_FMT1 = f"<{len(NAMES1)}I"
WAVES = ["正弦", "矩形", "のこぎり", "三角"]

# キー → ドからの半音数 (ピアノの並び。a=ド w=ド# s=レ ...)
KEYS = {"a": 0, "w": 1, "s": 2, "e": 3, "d": 4, "f": 5, "t": 6, "g": 7, "y": 8, "h": 9, "u": 10,
        "j": 11, "k": 12, "o": 13, "l": 14}

state = open("/sys/class/fpga_manager/fpga0/state").read().strip()
if state != "operating":
    sys.exit(f"PL が書き込まれていない (fpga0 state = {state})。fpgautil と devmem を先に")
def find_dev(addr):
    for d in glob.glob("/sys/class/rpmsg/rpmsg[0-9]*"):
        if os.path.realpath(d).endswith(f".rpmsg-raw.-1.{addr}/rpmsg/{os.path.basename(d)}"):
            return "/dev/" + os.path.basename(d)
    return None


def call(f, names, fmt, c, a=0, b=0):
    os.write(f, struct.pack("<4I", MAGIC_CMD, c, a, b))
    r = dict(zip(names, struct.unpack(fmt, os.read(f, 512)[:struct.calcsize(fmt)])))
    if r["magic"] != MAGIC_RES:
        sys.exit(f"返事の形が違う magic={r['magic']:#x}")
    return r


# 引数: [--r51] [--rev N] [keys|twinkle] [上限]  または  notes [秒] [上限]
args = sys.argv[1:]
r51 = "--r51" in args
if r51:
    args.remove("--r51")
rev = 64
if "--rev" in args:
    i = args.index("--rev")
    rev = int(args[i + 1])
    del args[i:i + 2]
mode = args.pop(0) if args and not args[0].isdigit() else "keys"
dur = float(args.pop(0)) if mode == "notes" and args else 30
limit = int(args[0]) if args else 256

dev = find_dev(ADDR)
if dev is None:
    sys.exit("音声の窓口 (rpmsg-raw, 0x420) がない。R5 は動いている? (r5_start.sh)")
fd = os.open(dev, os.O_RDWR)
fd1 = None
if r51:
    dev1 = find_dev(ADDR1)
    if dev1 is None:
        sys.exit("R5_1 の音の窓口 (rpmsg-raw, 0x460) がない。R5_1 は動いている? (r5_start.sh)")
    fd1 = os.open(dev1, os.O_RDWR)


def cmd(c, a=0, b=0):    # R5_0 (音声の窓口)
    return call(fd, NAMES, RES_FMT, c, a, b)


def cmd1(c, a=0, b=0):   # R5_1 (音の分業の窓口)
    return call(fd1, NAMES1, RES_FMT1, c, a, b)


def scmd(c, a=0, b=0):   # 音を作る命令 (9〜12) の宛先: 分業なら R5_1、でなければ R5_0
    return cmd1(c, a, b) if r51 else cmd(c, a, b)


def note(n, len_ms=300, vel=100):
    return scmd(9, n, len_ms | vel << 16)


def stats(r):
    s = (f"FIFO 残量 最小 {r['min_level']}  空 {r['n_empty']}回  1ms の処理 最長 {r['fill_max_us']} us")
    if not r51:
        return (f"音 {r['n_notes']}  遅れ 平均 {r['lat_avg_us']} us 最長 {r['lat_max_us']} us "
                f"({r['n_lat']} 回)  " + s)
    q = cmd1(5)
    return (f"[R5_1] 音 {q['n_notes']}  遅れ 平均 {q['lat_avg_us']} us 最長 {q['lat_max_us']} us "
            f"({q['n_lat']} 回)  作る時間 平均 {q['gen_avg_us']} us 最長 {q['gen_max_us']} us "
            f"({q['n_kick']} 回)  リバーブ {q['reverb']}\n"
            f"[R5_0] " + s + f"  輪バッファ不足 {r['n_ring_short']}回")


def pl_out_hdmi():
    # PL の出口 (0xA0000140 OUT_SEL bit0)。1 なら HDMI (stream_hdmi.bit + hdmi_audio.sh on)。
    # 音声設計でない (0x00 が 0xDEADBEEF でない) か読めなければ I2S とみなす
    try:
        fdm = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
        m = mmap.mmap(fdm, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xA0000000)
        ok = struct.unpack("<I", m[0:4])[0] == 0xDEADBEEF
        sel = struct.unpack("<I", m[0x140:0x144])[0] & 1 if ok else 0
        m.close()
        os.close(fdm)
        return sel == 1
    except OSError:
        return False


def dp_live_ok():
    # HDMI 側が PL の音を取りに来る設定か (hdmi_audio.sh on の値)。0xFD4AB070 bit5:4 = 00 (PL から)、
    # 0xFD4AB120 bit1 = 0 (音声クロックは PL)。起動直後に Linux が元に戻したことがあり、戻ると FIFO が減らず止まる
    fdm = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    m = mmap.mmap(fdm, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xFD4AB000)
    sel, clk = struct.unpack("<I", m[0x70:0x74])[0], struct.unpack("<I", m[0x120:0x124])[0]
    m.close()
    os.close(fdm)
    return (sel & 0x30) == 0 and (clk & 0x2) == 0, sel, clk


hdmi = pl_out_hdmi()
if hdmi:
    ok, sel, clk = dp_live_ok()
    if not ok:
        sys.exit(f"HDMI 側の設定が戻っている (0xFD4AB070={sel:#x} 0xFD4AB120={clk:#x})。sudo sh hdmi_audio.sh on をやり直す")
fs = 48000 if hdmi else 48828    # 標本の速さ。HDMI は 48kHz、I2S は 12.5MHz/256
if cmd(7, limit)["status"] != 0:
    sys.exit(f"上限 {limit} は範囲外 (1〜8192)")
cmd(15, fs)
if r51:
    cmd1(15, fs)
if r51:
    cmd1(6)            # R5_1 の統計を消す
    cmd1(14, rev)      # リバーブの量
    r = cmd(13, 1)     # R5_0: 輪バッファから流し始める
else:
    r = cmd(8, 1)
if r["status"] != 0:
    sys.exit({1: "PL が音声設計でない", 2: "再生中 (先に r5play.py --stop)",
              3: "R5_1 が輪バッファを用意していない (R5_1 は動いている?)"}.get(r["status"], r))
print(f"シンセ開始 ({'分業: R5_1 が作り R5_0 が流す、リバーブ ' + str(rev) if r51 else 'R5_0 だけ'}、"
      f"FIFO の上限 {limit} 段 = {limit * 1000 / fs:.1f} ms 分、出口 {'HDMI 48000Hz' if hdmi else 'I2S 48828Hz'})")

try:
    if mode == "twinkle":
        # きらきら星 (段3 と同じ並び)。4 分音符 = 400ms。1 小節ごとに低音 (1 オクターブ下の根音) を足す
        mel = [60, 60, 67, 67, 69, 69, 67, 0, 65, 65, 64, 64, 62, 62, 60, 0,
               67, 67, 65, 65, 64, 64, 62, 0, 67, 67, 65, 65, 64, 64, 62, 0,
               60, 60, 67, 67, 69, 69, 67, 0, 65, 65, 64, 64, 62, 62, 60, 0]
        bass = [48, 53, 48, 43, 48, 43, 48, 43, 48, 53, 48, 43]   # 半小節 (800ms) ごと
        mel, bass = mel[:8], bass[:4]   # 聞き比べ用に最初の 1 節だけ (3.2 秒。響きが消えるまで入れて約 5 秒)
        q = 400
        scmd(12, 0)
        for i, n in enumerate(mel):
            if n:
                hold = 2 if i + 1 < len(mel) and mel[i + 1] == 0 else 1   # 次が休みなら 2 拍
                scmd(11, i * q, n | 100 << 8 | (q * hold - 40) << 16)
        for i, n in enumerate(bass):
            scmd(11, i * 2 * q, n | 70 << 8 | (2 * q - 40) << 16)
        scmd(10, 3)   # 三角波
        r = scmd(12, 1)
        if r["status"] != 0:
            sys.exit(f"楽譜を始められない status={r['status']} (楽譜は最大 256 音)")
        while scmd(5)["score_run"]:
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
        print("白鍵 a s d f g h j k l / 黒鍵 w e t y u o   z/x オクターブ  1〜4 波形  "
              + ("r リバーブ  " if r51 else "") + "q 終わり")
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
                elif k == "r" and r51:
                    rev = {0: 64, 64: 128}.get(rev, 0)
                    cmd1(14, rev)
                    print(f"\rリバーブ: {rev}        ", end="", flush=True)
                elif k in "1234":
                    w = int(k) - 1
                    scmd(10, w)
                    print(f"\r波形: {WAVES[w]}        ", end="", flush=True)
        finally:
            termios.tcsetattr(0, termios.TCSADRAIN, old)
        print()
finally:
    r = cmd(13 if r51 else 8, 0)   # 止める (残りを鳴らし切る)
    print(stats(r))
