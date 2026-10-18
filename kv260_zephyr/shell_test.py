# Zephyr shell にコマンドを送って応答を記録する。プロンプトを待ってから順に送る
import sys, time, serial

port, out = sys.argv[1], sys.argv[2]
cmds = ["help", "kernel version", "kernel uptime", "kernel thread list", "demo ping"]
end = time.time() + 60
buf = b""
s = None
while time.time() < end and s is None:
    try:
        s = serial.Serial(port, 115200, timeout=0.2)
    except serial.SerialException:
        time.sleep(0.5)
# プロンプトが出るまで待つ
while time.time() < end and b"uart:~$" not in buf:
    buf += s.read(4096)
for c in cmds:
    s.write(c.encode() + b"\r")
    t = time.time() + 2
    while time.time() < t:
        buf += s.read(4096)
s.close()
open(out, "wb").write(buf)
