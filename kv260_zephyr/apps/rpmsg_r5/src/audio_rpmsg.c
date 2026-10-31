// -----------------------------------------------------------------------------
// audio_rpmsg.c -- R5 が音を途切れさせずに PL へ流す担当になる (Linux は指示を出すだけ)
//
//   Linux (linux/r5play.py)              R5 (ここ)                          PL (kv260_i2s2 の stream 設計)
//     音源を DDR 0x60000000 に置く
//     「再生 番地 長さ」を RPMsg で送る ─> 5ms ごとに FIFO の残量を見て ───>  0x00 DATA → FIFO(8192段)
//                                         空いた分を DDR から書き足す           → 音量・エコー → I2S → DAC
//     音量・エコー・停止・状態        <─> 返事 (再生位置・最小残量・空になった回数)
//
//   窓口: 名前 rpmsg-raw、番号 0x420 (Linux では virtio0.rpmsg-raw.-1.1056 の /dev/rpmsgN)
//
//   Linux の play.c (段5) は自分で FIFO を満たしていたので、Linux が忙しいと音が切れるおそれがあった。
//   ここでは R5 の優先度の高いスレッドが 5ms 周期で満たすので、Linux の負荷と関係なく流れ続ける。
//   本当にそうかは「最小残量」と「空になった回数」で測る。
//
//   命令 (Linux → R5、リトルエンディアン)  u32 magic = 0x43445541 ("AUDC")  u32 cmd  u32 a  u32 b
//     cmd 1 = 再生  a = DDR の物理番地  b = バイト数 (4 の倍数。1 語 = 左右 1 組。並びは dmaplay と同じ)
//     cmd 2 = 停止 (FIFO に残った分を鳴らし切ってから止める)
//     cmd 3 = 音量 a (64 で等倍)   cmd 4 = エコー a (0 で無し)
//     cmd 5 = 状態を返すだけ       cmd 6 = 統計を消す
//   返事 (どの命令にも 1 通)  u32 magic = 0x52445541 ("AUDR")  u32 status (0=正常 1=PLが音声設計でない 2=形式違い)
//     u32 playing  u32 pos (送ったバイト数)  u32 len  u32 level (今の残量)  u32 min_level  u32 n_empty
//     u32 n_tick  u32 fill_max_us (1 回の書き足しに掛かった最長時間)
//
//   ★PL は空のこともあるので、再生の命令が来るまで PL には触らない (0x00 が 0xDEADBEEF かを先に確かめる)
// -----------------------------------------------------------------------------
#include <zephyr/kernel.h>
#include <zephyr/shell/shell.h>
#include <zephyr/sys/sys_io.h>

#include <openamp/open_amp.h>

#define AUD_EPT_ADDR 0x420

#define AUD_BASE   0xA0000000UL   /* rpmsg.overlay の pl_axi で入出力領域として MPU 登録済み */
#define REG_DATA   (AUD_BASE + 0x00)   /* W: 1 組書く / R: 0xDEADBEEF */
#define REG_STATUS (AUD_BASE + 0x10)   /* bit0 満杯 bit1 空 bit29..16 残量 */
#define REG_CTRL   (AUD_BASE + 0x20)   /* bit0 再生 */
#define REG_GAIN   (AUD_BASE + 0x30)
#define REG_ECHO   (AUD_BASE + 0x40)
#define AUD_ID     0xDEADBEEFu
#define FIFO_DEPTH 8192

#define DDR_LO 0x60000000UL   /* rpmsg.overlay の pl_ddr (Linux 管理外の 512MB) */
#define DDR_HI 0x80000000UL

#define MAGIC_CMD 0x43445541u   /* "AUDC" */
#define MAGIC_RES 0x52445541u   /* "AUDR" */

#define PERIOD_MS 5

struct aud_cmd {
	uint32_t magic, cmd, a, b;
} __packed;

struct aud_res {
	uint32_t magic, status, playing, pos, len, level, min_level, n_empty, n_tick, fill_max_us;
} __packed;

static struct rpmsg_endpoint aud_ept;

/* 再生の状態。受信コールバック (管理スレッド) と書き足しスレッドの両方から触るので鍵を掛ける */
static K_MUTEX_DEFINE(lock);   /* 割り込みは止めない (初回の 8192 語書きが長いので) */
static uint32_t src_addr, src_len, src_pos;   /* DDR の番地・長さ・送り済み (バイト) */
static bool playing;    /* 書き足し中 */
static bool draining;   /* 停止命令の後、FIFO を鳴らし切るのを待っている */
static bool pl_used;    /* 一度でも PL を確かめた (それまで PL に触らない) */

/* 統計 */
static uint32_t level_now, min_level = FIFO_DEPTH, n_empty, n_tick;
static uint32_t fill_max_cyc;

static K_SEM_DEFINE(tick_sem, 0, 1);

static void tick_fn(struct k_timer *t)
{
	k_sem_give(&tick_sem);
}
static K_TIMER_DEFINE(tick_timer, tick_fn, NULL);

static void reset_stats(void)
{
	min_level = FIFO_DEPTH;
	n_empty = 0;
	n_tick = 0;
	fill_max_cyc = 0;
}

static uint32_t cyc_to_us(uint32_t c)
{
	return (uint32_t)((uint64_t)c * 1000000U / sys_clock_hw_cycles_per_sec());
}

/* FIFO の空き分だけ DDR から書き足す。戻り値は書いた語数 */
static uint32_t fill(void)
{
	uint32_t st = sys_read32(REG_STATUS);
	uint32_t level = (st >> 16) & 0x3FFF;
	uint32_t room = FIFO_DEPTH - level;
	uint32_t left = (src_len - src_pos) / 4;
	uint32_t n = MIN(room, left);
	uint32_t a = src_addr + src_pos;

	for (uint32_t i = 0; i < n; i++) {
		sys_write32(sys_read32(a + i * 4), REG_DATA);
	}
	src_pos += n * 4;
	return n;
}

/* ---- 書き足しスレッド (優先度 2。CNN は 5、shell はさらに下) ---- */
static void audio_thread(void *p1, void *p2, void *p3)
{
	for (;;) {
		k_sem_take(&tick_sem, K_FOREVER);
		k_mutex_lock(&lock, K_FOREVER);

		if (playing) {
			uint32_t st = sys_read32(REG_STATUS);

			level_now = (st >> 16) & 0x3FFF;
			n_tick++;
			/* 曲の途中で残量を見る。空なら音が途切れている */
			min_level = MIN(min_level, level_now);
			if (st & 0x2) {
				n_empty++;
			}
			uint32_t c0 = k_cycle_get_32();

			fill();
			fill_max_cyc = MAX(fill_max_cyc, k_cycle_get_32() - c0);
			if (src_pos >= src_len) {   /* 全部送った。あとは鳴らし切る */
				playing = false;
				draining = true;
			}
		} else if (draining) {
			uint32_t st = sys_read32(REG_STATUS);

			level_now = (st >> 16) & 0x3FFF;
			if (st & 0x2) {
				sys_write32(0, REG_CTRL);
				draining = false;
				k_timer_stop(&tick_timer);
			}
		}
		k_mutex_unlock(&lock);
	}
}
K_THREAD_DEFINE(audio_tid, 1024, audio_thread, NULL, NULL, NULL, 2, 0, 0);

static int do_cmd(const struct aud_cmd *c)
{
	if (!pl_used || c->cmd == 1) {
		if (c->cmd == 5 || c->cmd == 6) {
			return 0;   /* 状態を見るだけなら PL に触らない */
		}
		if (sys_read32(REG_DATA) != AUD_ID) {
			return 1;
		}
		pl_used = true;
	}
	switch (c->cmd) {
	case 1:
		if (c->a < DDR_LO || c->b == 0 || (c->a | c->b) & 3 || c->b > DDR_HI - c->a) {
			return 2;
		}
		if (playing || draining) {
			return 2;   /* 再生中 (先に止める) */
		}
		src_addr = c->a;
		src_len = c->b;
		src_pos = 0;
		reset_stats();
		/* FIFO は空のはず (前回は鳴らし切ってから止めている)。先に満たしてから鳴らし始める */
		sys_write32(0, REG_CTRL);
		fill();
		sys_write32(1, REG_CTRL);
		playing = src_pos < src_len;
		draining = !playing;
		k_timer_start(&tick_timer, K_MSEC(PERIOD_MS), K_MSEC(PERIOD_MS));
		return 0;
	case 2:
		if (playing) {
			playing = false;
			draining = true;
		}
		return 0;
	case 3:
		sys_write32(c->a & 0xFF, REG_GAIN);
		return 0;
	case 4:
		sys_write32(c->a & 0xFF, REG_ECHO);
		return 0;
	case 5:
		return 0;
	case 6:
		reset_stats();
		return 0;
	default:
		return 2;
	}
}

static int aud_cb(struct rpmsg_endpoint *e, void *data, size_t len, uint32_t src, void *priv)
{
	const struct aud_cmd *c = data;
	struct aud_res r = {.magic = MAGIC_RES};
	k_mutex_lock(&lock, K_FOREVER);

	if (len != sizeof(*c) || c->magic != MAGIC_CMD) {
		r.status = 2;
	} else {
		r.status = do_cmd(c);
	}
	r.playing = playing || draining;
	r.pos = src_pos;
	r.len = src_len;
	r.level = level_now;
	r.min_level = min_level;
	r.n_empty = n_empty;
	r.n_tick = n_tick;
	r.fill_max_us = cyc_to_us(fill_max_cyc);
	k_mutex_unlock(&lock);
	rpmsg_send(e, &r, sizeof(r));
	return RPMSG_SUCCESS;
}

int audio_rpmsg_init(struct rpmsg_device *rpdev)
{
	return rpmsg_create_ept(&aud_ept, rpdev, "rpmsg-raw", AUD_EPT_ADDR, RPMSG_ADDR_ANY, aud_cb,
				NULL);
}

/* ---- shell: audio stats ---- */
static int cmd_stats(const struct shell *sh, size_t argc, char **argv)
{
	shell_print(sh, "再生 %s / 送った %u / %u バイト", playing ? "中" : (draining ? "鳴らし切り中" : "停止"),
		    src_pos, src_len);
	shell_print(sh, "残量 今 %u 最小 %u (8192 段) / 空になった回数 %u / 見回り %u 回", level_now,
		    min_level, n_empty, n_tick);
	shell_print(sh, "1 回の書き足し 最長 %u us", cyc_to_us(fill_max_cyc));
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_audio,
	SHELL_CMD(stats, NULL, "音声の書き足しの統計", cmd_stats),
	SHELL_SUBCMD_SET_END);
SHELL_CMD_REGISTER(audio, &sub_audio, "PL の音声 FIFO (RPMsg で Linux から指示)", NULL);
