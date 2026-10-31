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
		# Zephyr の UART ドライバは初期化で UART1 の割り込みを全部止める (uart_xlnx_ps.c、IDR に全ビット)。
		# UART1 は Linux のコンソール (ttyPS1) と共用なので、そのままだと Linux がキー入力を受けられない。
		# Zephyr の初期化が終わるのを待って、Linux のドライバが入れる値 (CDNS_UART_RX_IRQS = 0x161) を
		# 割り込み有効レジスタ (IER, 0xFF010008) に書き戻す
		sleep 1
		devmem 0xFF010008 32 0x161
		echo "r5_start: UART1 の割り込みを戻した (IMR=$(devmem 0xFF010010 32))"
		exit 0
	fi
done
echo "r5_start: R5_0 の remoteproc がない (rpmsg.dtb で起動していない)"
exit 0
