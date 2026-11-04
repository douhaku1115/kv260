#!/bin/sh
# R5 のシンセを、普段と重い負荷 (audio_cmp.sh と同じ) で測る
# KV260 の ~ に r5synth.py を置き、PL は stream.bit + devmem 0xFF5E00C0
#   sh synth_cmp.sh 256
N=${1:-256}
load() {
	for i in 1 2 3 4 5 6 7 8; do (timeout 45 yes > /dev/null &) ; done
	(timeout 45 dd if=/dev/zero of=/home/petalinux/load.tmp bs=1M count=2000 conv=fsync 2>/dev/null &)
	sleep 5
}
unload() {
	pkill -x yes; pkill -x dd; sleep 3; rm -f /home/petalinux/load.tmp
}
echo "== 普段 (上限 $N)"; sudo python3 ~/r5synth.py notes 30 $N | tail -1
echo "== 負荷 (上限 $N)"; load; sudo python3 ~/r5synth.py notes 30 $N | tail -1; unload
