#!/usr/bin/env python3
# R5 の Zephyr の shell (/dev/rpmsgN) と対話する小さな端末。抜けるのは Ctrl+]
#   sudo python3 r5_term.py /dev/rpmsg1      (普通は r5_shell.sh から呼ぶ)
#
# socat ではキー入力が /dev/rpmsgN に一度も書かれなかった (「書き込める状態」を待つ作りで、
# rpmsg_char がそれを知らせないためと推測)。ここでは待たずに直接 write し、
# R5 からの返事は別スレッドで普通の read (ブロック) で受ける。poll/select は使わない。
import os
import sys
import termios
import threading
import tty

ESC = b"\x1d"   # Ctrl+]

dev = sys.argv[1] if len(sys.argv) > 1 else "/dev/rpmsg1"
fd = os.open(dev, os.O_RDWR)


def reader():
    while True:
        try:
            data = os.read(fd, 512)   # 1 回で RPMsg 1 通 (最大 496 バイト)
        except OSError:
            return
        if data:
            os.write(sys.stdout.fileno(), data)


threading.Thread(target=reader, daemon=True).start()

stdin = sys.stdin.fileno()
old = termios.tcgetattr(stdin) if os.isatty(stdin) else None
try:
    if old is not None:
        tty.setraw(stdin)
    os.write(fd, b"\r")   # R5 の shell は 1 通来るまで返信先を知らない。空行でプロンプトを出させる
    while True:
        key = os.read(stdin, 64)
        if not key:
            break
        if ESC in key:
            key = key.split(ESC)[0]
            if key:
                os.write(fd, key)
            break
        os.write(fd, key)
finally:
    if old is not None:
        termios.tcsetattr(stdin, termios.TCSADRAIN, old)
    os.close(fd)
    print("\r\n[r5_term] 終了")
