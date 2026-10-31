# Zephyr shell にコマンドを送って応答を記録する。プロンプトを待ってから順に送る
import sys, time, serial

port, out = sys.argv[1], sys.argv[2]
# 送るコマンドは第 3 引数以降。無ければ動作確認の定番を送る。
# "#sleep 秒" は送らずに、その秒数だけ受信を続ける (周期動作の様子を見るとき)
cmds = sys.argv[3:] or ["help", "kernel version", "kernel uptime", "kernel thread list", "demo ping"]
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
    if c.startswith("#sleep"):
        t = time.time() + float(c.split()[1])
    else:
        s.write(c.encode() + b"\r")
        t = time.time() + 2
    while time.time() < t:
        buf += s.read(4096)
s.close()
open(out, "wb").write(buf)
