#!/bin/sh
# R5 の Zephyr の shell (RPMsg、名前 rpmsg-raw・番号 0x440) に Linux からつなぐ
#   sudo r5_shell.sh                      対話。抜けるときは Ctrl+] (Ctrl+C は R5 の shell に届く)
#   sudo r5_shell.sh "kernel version" ... コマンドを順に送って応答を表示 (確認用)
#
# rpmsg-raw のチャネルは 2 本ある (0x400 = エコー、0x440 = shell)。どちらも /dev/rpmsgN になるので、
# sysfs の親デバイス名 (virtio0.rpmsg-raw.-1.1088 = 0x440) で shell の方を探す
ADDR=1088   # 0x440 (R5 側で使える番号は 0x400〜0x47F)

DEV=
for d in /sys/class/rpmsg/rpmsg[0-9]*; do
	[ -e "$d" ] || continue
	case "$(readlink -f "$d")" in
	*.rpmsg-raw.-1.$ADDR/*) DEV=/dev/$(basename "$d") ;;
	esac
done
if [ -z "$DEV" ]; then
	echo "r5_shell: shell のチャネル (rpmsg-raw, 0x440) がない。R5 は動いている? (r5_start.sh)"
	exit 1
fi

if [ $# -eq 0 ]; then
	echo "r5_shell: $DEV につなぐ (抜けるのは Ctrl+])"
	# socat はキー入力を /dev/rpmsgN に書かなかったので、自作の端末を使う (r5_term.py の説明)
	exec python3 /usr/local/bin/r5_term.py "$DEV"
fi

# コマンドを送って、少し待って応答を読む
exec 3<>"$DEV"
printf '\r' >&3            # R5 の shell はこちらから 1 通来るまで返信先を知らないので、まず空行
for c in "$@"; do
	sleep 0.2
	printf '%s\r' "$c" >&3
done
timeout 1 cat <&3
echo
