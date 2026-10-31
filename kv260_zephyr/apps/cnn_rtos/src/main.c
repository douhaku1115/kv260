// -----------------------------------------------------------------------------
// main.c -- Zephyr の部品 (タイマー・スレッド・セマフォ・ミューテックス・メッセージキュー・shell)
//           で PL の CNN を周期的に動かす
//
//   apps/cnn は「10 枚を順に 1 回だけ」だった。ここでは RTOS らしく役割をスレッドに分ける:
//
//     k_timer (割り込み) ──セマフォ──> 推論スレッド ──メッセージキュー──> 集計スレッド
//       周期ごとに時刻を記録       PL で 1 枚推論 (ミューテックスで PL を守る)   件数・不一致・遅れを数える
//
//   shell から操作する:
//     cnn start [周期 ms]   周期推論を始める (既定 100ms)
//     cnn stop              止める
//     cnn stats             件数・不一致・割り込みからスレッドが起きるまでの遅れ (最大/平均)
//     cnn once <番号>       画像 1 枚をその場で推論 (周期推論中でもミューテックスで順番待ち)
//     cnn watch on|off      周期推論の結果を 1 件ずつ表示する
//
//   遅れ (wake latency) は R5 のリアルタイム性の目安。タイマー割り込みで記録した時刻から、
//   推論スレッドがセマフォで起きた時刻までを k_cycle_get_32 (TTC 100MHz) で測る。
// -----------------------------------------------------------------------------
#include <stdlib.h>
#include <string.h>
#include <zephyr/kernel.h>
#include <zephyr/shell/shell.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/sys_io.h>

#include "cnn_data.h"

#define CNN_BASE   0xA0000000UL
#define REG_ID     (CNN_BASE + 0x00)
#define REG_STATUS (CNN_BASE + 0x10)
#define REG_CTRL   (CNN_BASE + 0x20)
#define REG_IMG    (CNN_BASE + 0x30)
#define REG_DIGIT  (CNN_BASE + 0x40)
#define REG_SEL    (CNN_BASE + 0x50)
#define REG_SCORE  (CNN_BASE + 0x60)

/* 推論 1 回分の結果 (推論スレッド → 集計スレッド) */
struct cnn_result {
	uint8_t img;      /* 画像番号 */
	uint8_t digit;    /* PL の答え */
	uint8_t bad;      /* 期待値との不一致の数 (答え + スコア 10 個) */
	uint32_t run_us;  /* 推論にかかった時間 */
	uint32_t wake_us; /* 割り込みからスレッドが起きるまで */
};

K_SEM_DEFINE(tick_sem, 0, 1);          /* タイマー → 推論スレッド */
K_MUTEX_DEFINE(pl_mutex);              /* PL の CNN は 1 つなので順番に使う */
K_MSGQ_DEFINE(result_q, sizeof(struct cnn_result), 16, 4);

static volatile uint32_t tick_cyc;     /* タイマー割り込みで記録した時刻 */
static volatile bool watch;

/* 集計 (集計スレッドだけが書く。shell は読むだけ) */
static struct {
	uint32_t count, bad, dropped;
	uint32_t wake_max_us;
	uint64_t wake_sum_us;
	uint32_t run_max_us;
} stats;

static uint32_t cyc_to_us(uint32_t cyc)
{
	return (uint32_t)((uint64_t)cyc * 1000000U / sys_clock_hw_cycles_per_sec());
}

/* PL で画像 n を推論し、期待値と照合する。呼ぶ側で pl_mutex を持つこと */
static void cnn_infer(int n, struct cnn_result *r)
{
	sys_write32(0x6, REG_CTRL);   /* 画素ポインタを戻し、終了フラグを消す */
	for (int i = 0; i < XLEN; i++) {
		sys_write32(test_images[n * XLEN + i], REG_IMG);
	}

	uint32_t c0 = k_cycle_get_32();

	sys_write32(0x1, REG_CTRL);
	while (!(sys_read32(REG_STATUS) & 0x2)) {
	}
	r->run_us = cyc_to_us(k_cycle_get_32() - c0);

	/* 期待される答え (同点は先勝ち。numpy.argmax と同じ) */
	int exp_digit = 0;

	for (int i = 1; i < NOUT; i++) {
		if ((int32_t)test_scores[n * NOUT + i] >
		    (int32_t)test_scores[n * NOUT + exp_digit]) {
			exp_digit = i;
		}
	}

	r->img = n;
	r->digit = sys_read32(REG_DIGIT) & 0xF;
	r->bad = (r->digit != exp_digit);
	for (int i = 0; i < NOUT; i++) {
		sys_write32(i, REG_SEL);
		if (sys_read32(REG_SCORE) != test_scores[n * NOUT + i]) {
			r->bad++;
		}
	}
}

/* ---- タイマー: 割り込みの中なので、時刻を記録してセマフォを渡すだけ ---- */
static void tick_fn(struct k_timer *t)
{
	tick_cyc = k_cycle_get_32();
	k_sem_give(&tick_sem);
}
K_TIMER_DEFINE(tick_timer, tick_fn, NULL);

/* ---- 推論スレッド: セマフォで起きて 1 枚推論し、結果をキューへ ---- */
static void infer_thread(void *a, void *b, void *c)
{
	int n = 0;

	for (;;) {
		k_sem_take(&tick_sem, K_FOREVER);

		struct cnn_result r;
		uint32_t wake = k_cycle_get_32() - tick_cyc;

		k_mutex_lock(&pl_mutex, K_FOREVER);
		cnn_infer(n, &r);
		k_mutex_unlock(&pl_mutex);
		r.wake_us = cyc_to_us(wake);

		if (k_msgq_put(&result_q, &r, K_NO_WAIT) != 0) {
			stats.dropped++;   /* 集計が追いつかないときだけ */
		}
		n = (n + 1) % NIMG;
	}
}
/* 推論を集計・shell より優先する (数字が小さいほど優先) */
K_THREAD_DEFINE(infer_tid, 2048, infer_thread, NULL, NULL, NULL, 2, 0, 0);

/* ---- 集計スレッド: キューから受け取って数える ---- */
static void stats_thread(void *a, void *b, void *c)
{
	struct cnn_result r;

	for (;;) {
		k_msgq_get(&result_q, &r, K_FOREVER);
		stats.count++;
		stats.bad += r.bad;
		stats.wake_sum_us += r.wake_us;
		stats.wake_max_us = MAX(stats.wake_max_us, r.wake_us);
		stats.run_max_us = MAX(stats.run_max_us, r.run_us);
		if (watch) {
			printk("[%u] 画像%u: 答え=%u %s 推論 %u us 遅れ %u us\n", stats.count, r.img,
			       r.digit, r.bad ? "不一致" : "一致", r.run_us, r.wake_us);
		}
	}
}
K_THREAD_DEFINE(stats_tid, 2048, stats_thread, NULL, NULL, NULL, 8, 0, 0);

/* ---- shell コマンド ---- */
static int cmd_start(const struct shell *sh, size_t argc, char **argv)
{
	uint32_t ms = (argc > 1) ? strtoul(argv[1], NULL, 0) : 100;

	if (ms < 3) {
		shell_error(sh, "周期は 3 ms 以上 (推論 1 枚に約 2 ms かかる)");
		return -EINVAL;
	}
	memset(&stats, 0, sizeof(stats));
	k_timer_start(&tick_timer, K_MSEC(ms), K_MSEC(ms));
	shell_print(sh, "周期 %u ms で推論を始めた", ms);
	return 0;
}

static int cmd_stop(const struct shell *sh, size_t argc, char **argv)
{
	k_timer_stop(&tick_timer);
	shell_print(sh, "止めた");
	return 0;
}

static int cmd_stats(const struct shell *sh, size_t argc, char **argv)
{
	shell_print(sh, "推論 %u 回 / 不一致 %u / 取りこぼし %u", stats.count, stats.bad,
		    stats.dropped);
	if (stats.count) {
		shell_print(sh, "遅れ (割り込み→スレッド) 最大 %u us 平均 %u us", stats.wake_max_us,
			    (uint32_t)(stats.wake_sum_us / stats.count));
		shell_print(sh, "推論時間 最大 %u us", stats.run_max_us);
	}
	return 0;
}

static int cmd_once(const struct shell *sh, size_t argc, char **argv)
{
	int n = strtol(argv[1], NULL, 0);

	if (n < 0 || n >= NIMG) {
		shell_error(sh, "番号は 0〜%d", NIMG - 1);
		return -EINVAL;
	}

	struct cnn_result r;

	k_mutex_lock(&pl_mutex, K_FOREVER);
	cnn_infer(n, &r);
	k_mutex_unlock(&pl_mutex);
	shell_print(sh, "画像%d: 答え=%u %s (%u us)", n, r.digit, r.bad ? "不一致" : "一致",
		    r.run_us);
	return 0;
}

static int cmd_watch(const struct shell *sh, size_t argc, char **argv)
{
	watch = (strcmp(argv[1], "on") == 0);
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_cnn,
	SHELL_CMD_ARG(start, NULL, "周期推論を始める: start [周期 ms]", cmd_start, 1, 1),
	SHELL_CMD(stop, NULL, "周期推論を止める", cmd_stop),
	SHELL_CMD(stats, NULL, "件数・不一致・遅れを表示", cmd_stats),
	SHELL_CMD_ARG(once, NULL, "1 枚だけ推論: once <番号>", cmd_once, 2, 0),
	SHELL_CMD_ARG(watch, NULL, "結果を 1 件ずつ表示: watch on|off", cmd_watch, 2, 0),
	SHELL_SUBCMD_SET_END);
SHELL_CMD_REGISTER(cnn, &sub_cnn, "PL の CNN を動かす", NULL);

int main(void)
{
	uint32_t id = sys_read32(REG_ID);

	printk("CNN ID = 0x%08X %s\n", id,
	       id == 0xC4400001u ? "(AXI 疎通 OK)" : "(違う: PL のビットファイルを確かめる)");
	return 0;
}
