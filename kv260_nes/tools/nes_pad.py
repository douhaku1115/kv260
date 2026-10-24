"""KV260 NES のコントローラ: PC のキーの押下・解放を読んで COM ポートへ送る。

  python tools/nes_pad.py [COM14]

小さな窓が開く。窓を選んだ状態でキーを押す (押している間ずっと押下になる)。
  矢印 / w a s d = 上下左右    x = A    z = B    Enter = Start    右 Shift / スペース = Select
  F5 = NES をリセット (ROM を書き直して再起動)    Esc = 終了
送る形式: 'P' + 押下状態 1 バイト ([0]A [1]B [2]Select [3]Start [4]上 [5]下 [6]左 [7]右、PAD と同じ)。
変化したとき、と 0.1 秒ごとに送る (main.c は 0.5 秒届かないと離したとみなす)。
Tera Term と同時には使えない (COM ポートは 1 つのプログラムしか開けない)。

ゲームパッド (pygame があれば): 十字キー / 左スティック = 方向、PAD_BTN の割り当てでボタン。
窓に押しているボタンの番号を出すので、割り当てが違えば PAD_BTN を直す。
キーとゲームパッドは同時に使える (両方の押下を合わせる)。
"""
import sys
import threading
import tkinter as tk

import serial

try:
    import pygame
except ImportError:
    pygame = None

# ゲームパッドのボタン番号 → NES のボタンのビット (Xbox One: 0=A 1=B 2=X 3=Y 6=ビュー 7=メニュー)
PAD_BTN = {0: 0, 3: 0,      # A, Y → A
           1: 1, 2: 1,      # B, X → B
           6: 2,            # ビュー → Select
           7: 3}            # メニュー → Start

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM14"

# キー名 (tkinter の keysym を小文字にしたもの) → ボタンのビット
KEYS = {
    "x": 0, "k": 0,                      # A
    "z": 1, "j": 1,                      # B
    "shift_r": 2, "space": 2,            # Select
    "return": 3,                         # Start
    "up": 4, "w": 4,
    "down": 5, "s": 5,
    "left": 6, "a": 6,
    "right": 7, "d": 7,
}
NAMES = ["A", "B", "Select", "Start", "上", "下", "左", "右"]

ser = serial.Serial(PORT, 115200, timeout=0.1)
held = set()            # 押しているキー名
last_sent = [-1]


joy = None
if pygame:
    pygame.init()
    pygame.joystick.init()
    if pygame.joystick.get_count() > 0:
        joy = pygame.joystick.Joystick(0)
        joy.init()
raw = [""]              # ゲームパッドで押しているボタン番号 (割り当て確認用)


def pad_state():
    """ゲームパッドの押下 (NES の並び)"""
    if joy is None:
        return 0
    pygame.event.pump()
    s = 0
    nums = []
    for i in range(joy.get_numbuttons()):
        if joy.get_button(i):
            nums.append(str(i))
            if i in PAD_BTN:
                s |= 1 << PAD_BTN[i]
    hx, hy = joy.get_hat(0) if joy.get_numhats() > 0 else (0, 0)
    ax, ay = joy.get_axis(0), joy.get_axis(1)
    if hy > 0 or ay < -0.5: s |= 1 << 4     # 上 (スティックは上がマイナス)
    if hy < 0 or ay > 0.5:  s |= 1 << 5     # 下
    if hx < 0 or ax < -0.5: s |= 1 << 6     # 左
    if hx > 0 or ax > 0.5:  s |= 1 << 7     # 右
    raw[0] = " ".join(nums)
    return s


def state():
    s = pad_state()
    for k in held:
        s |= 1 << KEYS[k]
    return s


def send(force=False):
    s = state()
    if force or s != last_sent[0]:
        ser.write(bytes([ord("P"), s]))
        last_sent[0] = s
        label.config(text="押下: " + (" ".join(NAMES[i] for i in range(8) if s >> i & 1) or "なし"))


def on_press(e):
    k = e.keysym.lower()
    if k == "escape":
        root.destroy()
    elif k == "f5":
        ser.write(b"r")
    elif k in KEYS:
        held.add(k)
        send()


def on_release(e):
    held.discard(e.keysym.lower())
    send()


def on_focus_out(_e):
    held.clear()        # 窓から離れたら全部離す (押しっぱなしを防ぐ)
    send()


last_line = [""]        # ボードから来た最後の 1 行 (reader が書き、tick が表示)


tick_n = [0]


def tick():
    # 約 60 回/秒 ゲームパッドを読み、変化で送る。0.1 秒ごとには変化が無くても送る
    tick_n[0] += 1
    send(force=(tick_n[0] % 6 == 0))
    if tick_n[0] % 6 == 0:
        msg.config(text=last_line[0])
        if joy is not None:
            padinfo.config(text=f"ゲームパッド: {joy.get_name()}  押しているボタン番号: {raw[0] or 'なし'}")
    root.after(16, tick)


def reader():
    """ボードからの文字 (PC=... など) を受け、最後の 1 行を覚える"""
    buf = b""
    while True:
        try:
            d = ser.read(256)
        except (serial.SerialException, TypeError):     # 窓を閉じてポートを閉じたあと
            return
        if d:
            buf = (buf + d)[-200:]
            lines = buf.replace(b"\r", b"").split(b"\n")
            if len(lines) > 1:
                last_line[0] = lines[-2].decode(errors="replace")


root = tk.Tk()
root.title(f"NES パッド ({PORT})")
tk.Label(root, text="この窓を選んでキーを押す\n矢印/wasd=方向  x=A  z=B  Enter=Start  スペース=Select\nF5=リセット  Esc=終了",
         justify="left", font=("Meiryo", 11)).pack(padx=12, pady=8)
label = tk.Label(root, text="押下: なし", font=("Meiryo", 14))
label.pack(padx=12, pady=4)
padinfo = tk.Label(root, text="ゲームパッド: なし" if joy is None else "", font=("Meiryo", 10))
padinfo.pack(padx=12, pady=2)
msg = tk.Label(root, text="", font=("Consolas", 10), fg="gray")
msg.pack(padx=12, pady=6)
root.bind("<KeyPress>", on_press)
root.bind("<KeyRelease>", on_release)
root.bind("<FocusOut>", on_focus_out)
threading.Thread(target=reader, daemon=True).start()
root.after(16, tick)
root.mainloop()
ser.write(b"P\x00")     # 終了時は全部離す
ser.close()
