// -----------------------------------------------------------------------------
// cnn_rpmsg.c -- Linux から RPMsg で頼まれた画像を PL の CNN で推論して返す (段2の続き)
//
//   Linux (linux/cnn_rpmsg.py)             R5 (ここ)                         PL (CNN, 0xA0000000)
//     画像 784 バイトを 2 通に分けて送る ─> 受信コールバック: 1 枚分ためる
//                                          推論スレッド: 画素を PL へ ──────>  推論 (約 2ms)
//     答え・スコア・推論時間を受け取る  <─ 結果を 1 通で返す
//
//   窓口: 名前 rpmsg-raw、番号 0x410 (Linux では virtio0.rpmsg-raw.-1.1040 の /dev/rpmsgN)
//   RPMsg の 1 通は最大 496 バイトなので、画像は分けて送る。
//
//   依頼 (Linux → R5、リトルエンディアン)
//     u32 magic = 0x494E4E43 ("CNNI")  u32 seq  u16 off  u16 len  u8 画素[len]
//     off は画像の中の位置 (0 から)。off + len = 784 の通が届いたら推論する
//   返事 (R5 → Linux)
//     u32 magic = 0x524E4E43 ("CNNR")  u32 seq  u32 status (0=正常 1=PLがCNNでない 2=形式違い)
//     u32 digit  u32 run_us (PL の推論時間)  i32 score[10]
//
//   ★R5 は電源投入時に自動で起動するが、PL はまだ空。空の PL の番地を読むと止まるおそれがあるので、
//    依頼が来るまで PL には触らない。PL の書き込み (fpgautil) とクロック (devmem) は Linux 側で先にやる。
// -----------------------------------------------------------------------------
#include <zephyr/kernel.h>
#include <zephyr/shell/shell.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/sys_io.h>
#include <string.h>

#include <openamp/open_amp.h>

#define CNN_EPT_ADDR 0x410   /* R5 側で使える番号は 0x400〜0x47F */

#define CNN_BASE   0xA0000000UL   /* pl_axi.overlay で MPU に入出力領域として登録 */
#define REG_ID     (CNN_BASE + 0x00)
#define REG_STATUS (CNN_BASE + 0x10)
#define REG_CTRL   (CNN_BASE + 0x20)
#define REG_IMG    (CNN_BASE + 0x30)
#define REG_DIGIT  (CNN_BASE + 0x40)
#define REG_SEL    (CNN_BASE + 0x50)
#define REG_SCORE  (CNN_BASE + 0x60)
#define CNN_ID     0xC4400001u

#define XLEN 784
#define NOUT 10

#define MAGIC_REQ 0x494E4E43u   /* "CNNI" */
#define MAGIC_RES 0x524E4E43u   /* "CNNR" */

struct cnn_req {
	uint32_t magic;
	uint32_t seq;
	uint16_t off;
	uint16_t len;
	uint8_t px[];
} __packed;

struct cnn_res {
	uint32_t magic;
	uint32_t seq;
	uint32_t status;
	uint32_t digit;
	uint32_t run_us;
	int32_t score[NOUT];
} __packed;

static struct rpmsg_endpoint cnn_ept;
static uint8_t img[XLEN];         /* 受信中の 1 枚 */
static uint32_t img_fill;         /* 届いた画素の数 */
static uint32_t img_seq;
static K_SEM_DEFINE(img_ready, 0, 1);
static volatile bool busy;        /* 推論中 (この間に次の画像が来たら形式違いとして数える) */

/* 統計 (shell の cnn stats) */
static uint32_t n_done, n_bad_msg, n_not_cnn;
static uint64_t run_sum_us;
static uint32_t run_min_us = UINT32_MAX, run_max_us;

/* 1 枚の処理の内訳 (サイクルの合計)。往復 4.4ms のうち PL の推論 2.1ms 以外がどこかを調べる */
enum { T_WAKE, T_PX, T_INFER, T_READ, T_SEND, T_N };
static const char *const t_name[T_N] = {"起床", "画素", "推論", "読出", "送信"};
static uint64_t t_sum[T_N];
static uint32_t c_rx;   /* 最後の断片を受けた時刻 */

/* ---- 受信 (管理スレッドの中): 画素をためるだけ。そろったら推論スレッドを起こす ---- */
static int cnn_cb(struct rpmsg_endpoint *e, void *data, size_t len, uint32_t src, void *priv)
{
	const struct cnn_req *q = data;

	if (len < sizeof(*q) || q->magic != MAGIC_REQ || len != sizeof(*q) + q->len ||
	    q->off + q->len > XLEN || busy) {
		n_bad_msg++;
		return RPMSG_SUCCESS;
	}
	if (q->off == 0) {
		img_fill = 0;
		img_seq = q->seq;
	}
	if (q->seq != img_seq || q->off != img_fill) {   /* 順番が飛んだ */
		n_bad_msg++;
		img_fill = 0;
		return RPMSG_SUCCESS;
	}
	memcpy(&img[q->off], q->px, q->len);
	img_fill += q->len;
	if (img_fill == XLEN) {
		c_rx = k_cycle_get_32();
		busy = true;
		k_sem_give(&img_ready);
	}
	return RPMSG_SUCCESS;
}

/* ---- 推論スレッド: 画素を PL に書いて推論し、結果を返す ---- */
static void cnn_thread(void *a, void *b, void *c)
{
	struct cnn_res r;

	for (;;) {
		k_sem_take(&img_ready, K_FOREVER);
		uint32_t c[T_N + 1];

		c[0] = c_rx;
		c[1] = k_cycle_get_32();   /* 起床 */
		memset(&r, 0, sizeof(r));
		r.magic = MAGIC_RES;
		r.seq = img_seq;

		if (sys_read32(REG_ID) != CNN_ID) {
			r.status = 1;
			n_not_cnn++;
		} else {
			sys_write32(0x6, REG_CTRL);   /* 画素ポインタを戻し、終了フラグを消す */
			for (int i = 0; i < XLEN; i++) {
				sys_write32(img[i], REG_IMG);
			}
			uint32_t c0 = k_cycle_get_32();

			c[2] = c0;   /* 画素を書き終えた */

			/* 終了待ちは空回りしない (Linux は返事を受けるとすぐ次を頼むので、空回りすると
			 * shell など優先の低いスレッドが動けなくなる。段3で確認)。1 ティック (1ms) ずつ休む
			 */
			sys_write32(0x1, REG_CTRL);
			while (!(sys_read32(REG_STATUS) & 0x2)) {
				k_sleep(K_TICKS(1));
			}
			c[3] = k_cycle_get_32();   /* 推論が終わった */
			r.run_us = (uint32_t)((uint64_t)(c[3] - c0) * 1000000U /
					      sys_clock_hw_cycles_per_sec());
			r.digit = sys_read32(REG_DIGIT) & 0xF;
			for (int i = 0; i < NOUT; i++) {
				sys_write32(i, REG_SEL);
				r.score[i] = (int32_t)sys_read32(REG_SCORE);
			}
			c[4] = k_cycle_get_32();   /* スコアを読み終えた */
			n_done++;
			run_sum_us += r.run_us;
			run_min_us = MIN(run_min_us, r.run_us);
			run_max_us = MAX(run_max_us, r.run_us);
		}
		img_fill = 0;
		busy = false;
		rpmsg_send(&cnn_ept, &r, sizeof(r));
		if (r.status == 0) {
			c[5] = k_cycle_get_32();   /* 返事を送り終えた */
			for (int i = 0; i < T_N; i++) {
				t_sum[i] += c[i + 1] - c[i];
			}
		}
	}
}
K_THREAD_DEFINE(cnn_tid, 1024, cnn_thread, NULL, NULL, NULL, 5, 0, 0);

int cnn_rpmsg_init(struct rpmsg_device *rpdev)
{
	return rpmsg_create_ept(&cnn_ept, rpdev, "rpmsg-raw", CNN_EPT_ADDR, RPMSG_ADDR_ANY, cnn_cb,
				NULL);
}

/* ---- shell: cnn stats ---- */
static int cmd_stats(const struct shell *sh, size_t argc, char **argv)
{
	shell_print(sh, "推論 %u 枚 / 形式違い %u / PL が CNN でない %u", n_done, n_bad_msg, n_not_cnn);
	if (n_done) {
		shell_print(sh, "PL の推論時間 最小 %u us 平均 %u us 最大 %u us", run_min_us,
			    (uint32_t)(run_sum_us / n_done), run_max_us);
		/* 内訳 (1 枚あたりの平均)。起床 = 最後の断片を受けてから推論スレッドが動くまで */
		uint64_t hz = sys_clock_hw_cycles_per_sec();

		for (int i = 0; i < T_N; i++) {
			shell_print(sh, "  %s %u us", t_name[i],
				    (uint32_t)(t_sum[i] * 1000000U / hz / n_done));
		}
	}
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_cnn,
	SHELL_CMD(stats, NULL, "Linux から頼まれた推論の統計", cmd_stats),
	SHELL_SUBCMD_SET_END);
SHELL_CMD_REGISTER(cnn, &sub_cnn, "PL の CNN (RPMsg で Linux から依頼)", NULL);
