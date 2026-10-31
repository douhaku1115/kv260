#!/bin/sh
# R5_0 で RPMsg 用の Zephyr (/lib/firmware/rpmsg_r5.elf) を起動する (段2の自動化)
#   r5-rpmsg.service から起動時に呼ばれる。手で呼んでもよい: sudo /usr/local/bin/r5_start.sh
#   rpmsg.dtb で起動していない (R5 のノードがない) ときは何もしないで終わる
FW=rpmsg_r5.elf

modprobe rpmsg_char

for r in /sys/class/remoteproc/remoteproc*; do
	[ -e "$r/name" ] || continue
	if [ "$(cat "$r/name")" = "ffe00000.r5f" ]; then   # R5_0 (番号は起動ごとに変わりうるので名前で探す)
		if [ "$(cat "$r/state")" = "running" ]; then
			echo "r5_start: $r はもう動いている"
			exit 0
		fi
		echo "$FW" > "$r/firmware"
		echo start > "$r/state"
		echo "r5_start: $r ($FW) → $(cat "$r/state")"
		exit 0
	fi
done
echo "r5_start: R5_0 の remoteproc がない (rpmsg.dtb で起動していない)"
exit 0
