#!/bin/sh
# R5_0 と R5_1 で RPMsg 用の Zephyr を起動する (段2の自動化)
#   R5_0 (ffe00000.r5f): /lib/firmware/rpmsg_r5.elf    音・CNN など PL を使う仕事
#   R5_1 (ffe90000.r5f): /lib/firmware/rpmsg_r5_1.elf  重い計算 (elf が無ければ起動しない)
#   r5-rpmsg.service から起動時に呼ばれる。手で呼んでもよい: sudo /usr/local/bin/r5_start.sh
#   rpmsg.dtb で起動していない (R5 のノードがない) ときは何もしないで終わる
# 2 つの Zephyr は割り込みコントローラ (GIC) を共用するので、どちらも CONFIG_GIC_SAFE_CONFIG で作ってある
# (先に起動した側だけが初期化し、各自が自分の割り込みだけを自分宛てにする)

modprobe rpmsg_char

# start <remoteproc の名前> <elf>。成功なら 0
start() {
	for r in /sys/class/remoteproc/remoteproc*; do
		[ -e "$r/name" ] || continue
		[ "$(cat "$r/name")" = "$1" ] || continue   # 番号は起動ごとに変わりうるので名前で探す
		if [ "$(cat "$r/state")" = "running" ]; then
			echo "r5_start: $1 はもう動いている"
			return 1
		fi
		echo "$2" > "$r/firmware"
		echo start > "$r/state"
		echo "r5_start: $1 ($2) → $(cat "$r/state")"
		return 0
	done
	echo "r5_start: $1 の remoteproc がない (rpmsg.dtb で起動していない)"
	return 1
}

if start ffe00000.r5f rpmsg_r5.elf; then
	# Zephyr の UART ドライバは初期化で UART1 の割り込みを全部止める (uart_xlnx_ps.c、IDR に全ビット)。
	# UART1 は Linux のコンソール (ttyPS1) と共用なので、そのままだと Linux がキー入力を受けられない。
	# Zephyr の初期化が終わるのを待って、Linux のドライバが入れる値 (CDNS_UART_RX_IRQS = 0x161) を
	# 割り込み有効レジスタ (IER, 0xFF010008) に書き戻す (R5_1 は UART を使わないので不要)
	sleep 1
	devmem 0xFF010008 32 0x161
	echo "r5_start: UART1 の割り込みを戻した (IMR=$(devmem 0xFF010010 32))"
fi

if [ -e /lib/firmware/rpmsg_r5_1.elf ]; then
	start ffe90000.r5f rpmsg_r5_1.elf
fi
exit 0
