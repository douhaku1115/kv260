// -----------------------------------------------------------------------------
// ipi_early_clear.h -- 起動直後に自分の IPI の残りを消す (R5_0 / R5_1 共通。各アプリの .c で 1 回だけ include)
//
//   なぜ要るか (段B で R5_1 が起動しなかった原因):
//     GIC の分配器は Linux・R5_0・R5_1 で共有 (CONFIG_GIC_SAFE_CONFIG) なので、前回の R5 が有効にした
//     IPI の割り込み (R5_1 なら SPI 34) は R5 を止めても有効のまま残る。止めた時に IPI の ISR に
//     ビット (Linux や相手の R5 からの合図) が残っていると、次に起動した R5 は割り込みが解禁された
//     瞬間 (POST_KERNEL の最初) に割り込みが鳴りっぱなしになる。IPI ドライバ (POST_KERNEL 優先度 40)
//     が ISR を消すより前なので、誰も消さず main に永遠に届かない。
//   対策: 割り込みがまだ禁止されている PRE_KERNEL_1 で、ドライバの初期化と同じこと
//     (IDR に全部 1 = 全部閉じる、ISR に全部 1 = 残りを消す) を先にやっておく。
//     開け直すのは従来どおりドライバの ipm_set_enabled。
// -----------------------------------------------------------------------------
#ifndef IPI_EARLY_CLEAR_H
#define IPI_EARLY_CLEAR_H

#include <zephyr/init.h>
#include <zephyr/sys/sys_io.h>
#include <zephyr/devicetree.h>

#define IPI_EARLY_ISR 0x10
#define IPI_EARLY_IDR 0x1C

/* node: 自分の IPI (R5_0 は rpu0_ipi = 0xFF310000、R5_1 は rpu1_ipi = 0xFF320000) */
#define IPI_EARLY_CLEAR(node)                                                            \
	static int ipi_early_clear(void)                                                 \
	{                                                                                \
		sys_write32(0xFFFFFFFFu, DT_REG_ADDR(node) + IPI_EARLY_IDR);             \
		sys_write32(0xFFFFFFFFu, DT_REG_ADDR(node) + IPI_EARLY_ISR);             \
		return 0;                                                                \
	}                                                                                \
	SYS_INIT(ipi_early_clear, PRE_KERNEL_1, 0)

#endif
