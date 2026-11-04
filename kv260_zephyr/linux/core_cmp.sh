#!/bin/sh
# R5_1 が重い計算をしていても R5_0 の音 (シンセ) が乱れないかを測る
# KV260 の ~ に r5synth.py と r5_1_calc.py を置き、PL は stream.bit + devmem 0xFF5E00C0
#   sh core_cmp.sh 128
N=${1:-128}
load() {
	for i in 1 2 3 4 5 6 7 8; do (timeout 45 yes > /dev/null &) ; done
	(timeout 45 dd if=/dev/zero of=/home/petalinux/load.tmp bs=1M count=2000 conv=fsync 2>/dev/null &)
	sleep 5
}
unload() {
	pkill -x yes; pkill -x dd; sleep 3; rm -f /home/petalinux/load.tmp
}
echo "== (a) シンセだけ (上限 $N)"
sudo python3 ~/r5synth.py notes 30 $N | tail -1
echo "== (b) R5_1 が計算し続ける間"
sudo python3 ~/r5_1_calc.py 200000 36 > /tmp/calc.txt &
sleep 2
sudo python3 ~/r5synth.py notes 30 $N | tail -1
wait; cat /tmp/calc.txt
echo "== (c) R5_1 の計算 + Linux に重い負荷"
load
sudo python3 ~/r5_1_calc.py 200000 36 > /tmp/calc.txt &
sleep 2
sudo python3 ~/r5synth.py notes 30 $N | tail -1
wait; cat /tmp/calc.txt
unload
