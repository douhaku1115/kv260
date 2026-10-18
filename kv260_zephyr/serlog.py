# 指定の COM を指定秒数だけ読んでファイルに書く。
# 基板の電源を抜くと USB-UART ごと消えるので、切れたら開き直す
import sys, time, serial

port, secs, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
end = time.time() + secs
s = None
with open(out, "ab") as f:
    while time.time() < end:
        if s is None:
            try:
                s = serial.Serial(port, 115200, timeout=0.2)
            except serial.SerialException:
                time.sleep(0.5)
                continue
        try:
            d = s.read(4096)
        except serial.SerialException:
            s.close()
            s = None
            continue
        if d:
            f.write(d)
            f.flush()
if s is not None:
    s.close()
