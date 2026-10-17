# COM14 に文字を送る。使い方: sendkey.py <文字列> <回数> <間隔秒>
import sys, time, serial

keys, n, gap = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
s = serial.Serial("COM14", 115200, timeout=0.05)
buf = b""
for _ in range(n):
    s.write(keys.encode())
    end = time.time() + gap
    while time.time() < end:
        buf += s.read(4096)
end = time.time() + 0.5
while time.time() < end:
    buf += s.read(4096)
s.close()
print(buf.decode("utf-8", "replace").replace("\r", "")[-300:])
