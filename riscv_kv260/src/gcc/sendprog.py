#!/usr/bin/env python3
# sendprog.py <device> <prog.c>  : prog.c を mkload.sh でコンパイル→固定リンクし、
#   モニタの load コマンド+hex を「エコー同期」で1語ずつ確実に送信する。
#   各語を送ったらモニタのエコー(0x........)を待ってから次を送る=FIFO溢れ/混入を防ぐ。
#   ポート開閉のライン揺れ抑制のため dsrdtr/rtscts を無効化し開後に入力を捨てる。
#   tio は一旦終了(ctrl-t q)してから実行。終わったら再度 tio で対話可。
import sys, os, time, re, subprocess
try:
    import serial
except ImportError:
    sys.exit("pyserial が必要: pip install pyserial")

if len(sys.argv) != 3:
    sys.exit("usage: sendprog.py <device e.g. /dev/ttyUSB4> <prog.c>")
dev, csrc = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))

out = subprocess.check_output(["bash", os.path.join(here, "mkload.sh"), csrc],
                              stderr=subprocess.DEVNULL).decode()
lines = [l.strip() for l in out.splitlines() if l.strip()]
loadline = next(l for l in lines if l.startswith("load "))
words = next(l for l in lines if not l.startswith("load ")).split()
n = int(loadline.split()[1])
assert len(words) == n, f"語数不一致: load {n} だが hex {len(words)}"

ser = serial.Serial(dev, 115200, timeout=0.05, rtscts=False, dsrdtr=False)

def read_for(sec):
    """sec 秒だけ読み、受信文字列を返す"""
    end = time.time() + sec; buf = b""
    while time.time() < end:
        b = ser.read(256)
        if b: buf += b; end = time.time() + 0.05   # 受信中は延長
    return buf.decode(errors="replace")

tok = re.compile(r"0x[0-9a-fA-F]{8}")

time.sleep(0.3); ser.reset_input_buffer()          # 開後の揺れ・残バイトを捨てる
ser.write((loadline + "\r").encode()); ser.flush()
# "send N hex words:" プロンプトを待つ
prompt = ""
t0 = time.time()
while "words:" not in prompt and time.time()-t0 < 3:
    prompt += read_for(0.2)
sys.stdout.write(prompt)
ser.reset_input_buffer()                           # 語送信直前に入力バッファを空に

ok = 0
for i, w in enumerate(words):
    ser.write((w + " ").encode()); ser.flush()
    echo = ""                                      # この語のエコー(0x........)を待つ
    t0 = time.time()
    while not tok.search(echo) and time.time()-t0 < 0.5:
        echo += read_for(0.05)
    sys.stdout.write(echo); sys.stdout.flush()
    m = tok.search(echo)
    if m and int(m.group()[2:], 16) == int(w, 16):
        ok += 1
    else:
        sys.stdout.write(f"\n[!] {i+1}語目 不一致(送:{w} 受:{m.group() if m else 'なし'})\n")

sys.stdout.write(read_for(0.8))                    # run.../ret= を表示
print(f"\n--- 一致 {ok}/{n} 語 ---")
ser.close()
