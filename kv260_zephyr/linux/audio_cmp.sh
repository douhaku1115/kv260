#!/bin/sh
# 上限 N 段で「Linux だけ (linplay)」と「R5 (r5play.py)」を、普段と重い負荷で比べる
# KV260 の ~ に linplay (gcc -O2 -o linplay linplay.c)・r5play.py・song.raw を置き、PL は stream.bit + devmem 0xFF5E00C0
#   sh audio_cmp.sh 384
N=${1:-512}
load() {
	for i in 1 2 3 4 5 6 7 8; do (timeout 45 yes > /dev/null &) ; done
	(timeout 45 dd if=/dev/zero of=/home/petalinux/load.tmp bs=1M count=2000 conv=fsync 2>/dev/null &)
	sleep 5
}
unload() {
	pkill -x yes; pkill -x dd; sleep 3; rm -f /home/petalinux/load.tmp
}
echo "== Linux 普段";  sudo ./linplay ~/song.raw 20 $N
echo "== R5 普段";     sudo python3 ~/r5play.py ~/song.raw 20 $N | tr '\r' '\n' | tail -1
echo "== Linux 負荷";  load; sudo ./linplay ~/song.raw 30 $N; unload
echo "== R5 負荷";     load; sudo python3 ~/r5play.py ~/song.raw 30 $N | tr '\r' '\n' | tail -1; unload
