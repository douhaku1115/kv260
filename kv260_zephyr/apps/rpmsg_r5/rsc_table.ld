/*
 * リソーステーブルを BTCM (書き込める RAM) に、コピーなしで置く
 *
 * 何もしないと XIP のため ATCM (R5 からは読み取り専用) に置かれる。Linux はこのテーブルに
 * vring の番地や状態を書き込み、R5 側も状態を書き戻すことがあるので、書き込める場所に置く。
 * 置き場所 = 読み込み先 (VMA = LMA) にして、起動時の「ROM→RAM コピー」の対象から外す
 * (コピーされると Linux が書いた内容が上書きされる)。
 */
SECTION_PROLOGUE(.resource_table,,)
{
	KEEP(*(.resource_table*))
} GROUP_DATA_LINK_IN(RAMABLE_REGION, RAMABLE_REGION)
