#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# spectrum_view.py -- KV260 から届くスペクトルをパソコンでリアルタイム棒グラフ表示
#
#   パソコン側で実行（matplotlib と numpy が必要）:
#     pip install matplotlib numpy
#     python spectrum_view.py
#
#   KV260 側（送信先はこのパソコンのIP。echo $SSH_CLIENT の先頭で分かる）:
#     sudo ./play song.raw <このパソコンのIP>
# -----------------------------------------------------------------------------
import socket
import struct
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.animation as animation

NSEND = 840               # play.c から届く低域ビン数（0〜約5000Hz）
NFFT  = 8192
PORT  = 50007

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("", PORT))
sock.setblocking(False)

vals = np.zeros(NSEND)

# 日本語が文字化けしないようフォントを指定（Windows標準）
plt.rcParams["font.family"] = "Meiryo"
plt.rcParams["axes.unicode_minus"] = False

FS    = 48828.125
freqs = np.arange(NSEND) * FS / NFFT   # 各ビンの周波数[Hz]（分解能 ≒ 5.96Hz）

fig, ax = plt.subplots(figsize=(10, 4))
line, = ax.plot(freqs, vals, color="deepskyblue", linewidth=1)
ax.set_ylim(0, 4_000_000)          # 縦軸の最大 = 4.00（×10^6）
ax.set_xlim(0, 5000)               # 0 〜 5kHz
ax.set_xticks(np.arange(0, 5001, 500))   # 500Hz 刻みの目盛
ax.set_title("KV260 リアルタイムスペクトル")
ax.set_xlabel("周波数 [Hz]　（左＝低音　右＝高音）")
ax.set_ylabel("振幅（音の強さ）")
ax.grid(True, alpha=0.3)

def update(_):
    global vals
    try:
        while True:                        # 溜まっている分は最新まで読み捨てる
            data, _addr = sock.recvfrom(8192)
            vals = np.array(struct.unpack("%df" % NSEND, data))
    except BlockingIOError:
        pass
    line.set_ydata(vals)
    return line,

ani = animation.FuncAnimation(fig, update, interval=30, blit=False)
plt.tight_layout()
plt.show()
