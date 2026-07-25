#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# spectrum_view.py -- KV260 から届くスペクトルをパソコンでリアルタイム表示
#   dB軸・塗りつぶし・ピークホールド・時間平滑化 で見やすくした版
#
#   パソコン側（matplotlib と numpy が必要）:
#     pip install matplotlib numpy
#     python spectrum_view.py
#
#   KV260 側（送信先はこのパソコンのIP）:
#     sudo ./play song.raw <このパソコンのIP>
# -----------------------------------------------------------------------------
import socket
import struct
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.animation as animation

NSEND = 1680              # play.c から届く低域ビン数（0〜約10000Hz）
NFFT  = 8192
PORT  = 50007
FS    = 48828.125

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("", PORT))
sock.setblocking(False)

freqs = np.arange(NSEND) * FS / NFFT          # 各ビンの周波数[Hz]

# 日本語が文字化けしないようフォントを指定（Windows標準）
plt.rcParams["font.family"] = "Meiryo"
plt.rcParams["axes.unicode_minus"] = False

FLOOR   = 20.0            # dB表示の下限（塗りつぶしの底）
SMOOTH  = 0.4             # 時間平滑化（大きいほど反応が速い）
DROP    = 1.0            # ピークの下降速度 [dB/フレーム]

vals = np.zeros(NSEND)                          # 平滑化した振幅
peak = np.full(NSEND, FLOOR)                    # ピークホールド[dB]

def to_db(v):
    return 20.0 * np.log10(np.maximum(v, 1.0))  # 振幅→dB（0対策で下限1）

fig, ax = plt.subplots(figsize=(11, 5))
db0 = to_db(vals)
fill = ax.fill_between(freqs, FLOOR, db0, color="deepskyblue", alpha=0.5)
line, = ax.plot(freqs, db0, color="deepskyblue", linewidth=1.2)
peakline, = ax.plot(freqs, peak, color="crimson", linewidth=0.8, label="ピーク")

ax.set_ylim(FLOOR, 150)
ax.set_xlim(0, 10000)
ax.set_xticks(np.arange(0, 10001, 1000))
ax.set_title("KV260 リアルタイムスペクトル")
ax.set_xlabel("周波数 [Hz]　（左＝低音　右＝高音）")
ax.set_ylabel("レベル [dB]")
ax.grid(True, alpha=0.3)
ax.legend(loc="upper right")

def update(_):
    global vals, peak, fill
    new = None
    try:
        while True:                             # 溜まっている分は最新まで読み捨てる
            data, _addr = sock.recvfrom(8192)
            new = np.array(struct.unpack("%df" % NSEND, data))
    except BlockingIOError:
        pass
    if new is not None:
        vals = vals * (1.0 - SMOOTH) + new * SMOOTH   # 時間平滑化

    db = to_db(vals)
    peak = np.maximum(peak - DROP, db)          # ピークホールド（ゆっくり下降）

    line.set_ydata(db)
    peakline.set_ydata(peak)
    fill.remove()                               # 塗りつぶしを更新
    fill = ax.fill_between(freqs, FLOOR, db, color="deepskyblue", alpha=0.5)
    return line, peakline, fill

ani = animation.FuncAnimation(fig, update, interval=30, blit=False)
plt.tight_layout()
plt.show()
