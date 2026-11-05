#!/bin/sh
# hdmi_audio.sh -- R5 の音を HDMI モニターから出す設定 (PL は kv260_i2s2 の stream_hdmi.bit)
#   sudo sh hdmi_audio.sh on       PL の FIFO の出口を HDMI に。HDMI 側の音声の入力元を PL (live)、音声クロックも PL に
#   sudo sh hdmi_audio.sh off      元に戻す (PL は I2S、HDMI 側は Linux の ALSA が使う形)
#   sudo sh hdmi_audio.sh status   レジスタを表示
#
#   先に (電源を入れるたびに):
#     sudo fpgautil -b stream_hdmi.bit
#     sudo devmem 0xFF5E00C0 32 0x01010A00      (PL のクロック pl_clk0 = 100MHz)
#   HDMI 出力のドライバが動いていること (r5_rpmsg + dp_audio の rpmsg.dtb で起動。linux/dp_audio.dtso)
#
#   レジスタ (Vitis の avbuf / dppsu ドライバのヘッダ、2026-11-05 に Linux が鳴らしている最中の値を読んで確認):
#     0xFD4AB070 AV_BUF 出力選択   bit5:4 = 音声1 の入力元 (00 = PL から live、01 = メモリ = Linux の ALSA)
#                                  bit6   = 音声2 (グラフィックス用)。live では使わないので 0
#     0xFD4AB120 クロック元        bit1   = 音声クロック (0 = PL の dp_s_axis_audio_clk、1 = PS)
#     0xFD4ACC00 音声リセット      bit0   = 1 → 0 でリセット
#     0xFD4A0300 HDMI 送信の音声   bit0   = 有効 (Linux は鳴らす間だけ 1 にする)
#     0xFD4A0304 チャンネル数 - 1  1 = 2ch (起動時から 1)
#     0xFD4AC000 音量              [15:0] 左 [31:16] 右。0x2000 で等倍 (テンプレートと Linux が書く値)
#   ★起動直後、on にした後で Linux が 070 と 120 を元 (0x54 / 0x07) に書き戻したことがある (原因は未特定)。
#     戻ると HDMI は PL の音を取りに来ず、FIFO が減らない。status で確かめ、戻っていたら on をやり直す
#     0xA0000140 PL の OUT_SEL     bit0   = 1 で FIFO を HDMI の速さ (48kHz) で読む (rtl/i2s_stream_axi.v)
#     0xA0000150 PL の HDMI_EMPTY  HDMI が欲しい時に FIFO が空だった回数
set -e

rd() { devmem "$1" 32; }
wr() { devmem "$1" 32 "$2"; }

check_pl() {
	if [ "$(rd 0xA0000000)" != "0xDEADBEEF" ]; then
		echo "PL が音声設計でない (0xA0000000 が 0xDEADBEEF でない)。fpgautil と devmem を先に" >&2
		exit 1
	fi
}

case "$1" in
on)
	check_pl
	wr 0xA0000140 1
	v=$(rd 0xFD4AB070); wr 0xFD4AB070 $(printf "0x%08X" $((v & ~0x70)))
	v=$(rd 0xFD4AB120); wr 0xFD4AB120 $(printf "0x%08X" $((v & ~0x2)))
	wr 0xFD4ACC00 1
	wr 0xFD4ACC00 0
	wr 0xFD4A0304 1
	wr 0xFD4AC000 0x20002000   # 音量 等倍。起動後に Linux が一度も鳴らしていないと 0 (消音) のまま
	wr 0xFD4A0300 1
	echo "HDMI 音声: PL から (48kHz)"
	;;
off)
	wr 0xFD4A0300 0
	v=$(rd 0xFD4AB070); wr 0xFD4AB070 $(printf "0x%08X" $(((v & ~0x70) | 0x50)))
	v=$(rd 0xFD4AB120); wr 0xFD4AB120 $(printf "0x%08X" $((v | 0x2)))
	if [ "$(rd 0xA0000000)" = "0xDEADBEEF" ]; then wr 0xA0000140 0; fi
	echo "HDMI 音声: 元に戻した (PL は I2S)"
	;;
status)
	for a in 0xFD4AB070 0xFD4AB120 0xFD4A0300 0xFD4A0304 0xFD4AC000 0xA0000140 0xA0000150; do
		echo "$a $(rd $a)"
	done
	;;
*)
	echo "使い方: sudo sh hdmi_audio.sh on|off|status" >&2
	exit 1
	;;
esac
