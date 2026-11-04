// -----------------------------------------------------------------------------
// r51_audio.c -- 音の分業 (R5_1 側): R5_1 が音を作ってリバーブを掛け、共有 DDR の輪バッファに書く
//
//   Linux (r5synth.py --r51)        R5_1 (ここ)                         R5_0 (audio_rpmsg.c 命令 13)
//     音符・波形・楽譜・リバーブ ─> 0x460 窓口
//                                   KICK を受けたら輪バッファが          1ms ごとに輪バッファ → PL の FIFO
//                                   TARGET 標本になるまで作って書く <── KICK (IPI、Linux を通さない)
//
//   音を作る部分は R5_0 の synth.c をそのまま使う (synth_next)。そのあとにリバーブ (残響) を掛ける。
//   リバーブは Freeverb の形 (並列の櫛形フィルタ 4 本 → 全域通過フィルタ 2 本) を整数で組んだもの。
//
//   命令 (Linux → R5_1)  u32 magic = 0x43445541 ("AUDC")  u32 cmd  u32 a  u32 b   (R5_0 の音声と同じ形)
//     5 状態  6 統計を消す  9 音符  10 波形  11 楽譜に足す  12 楽譜 (中身は R5_0 と同じ)
//     14 リバーブの量 a (0 = 無し、64 が既定、255 まで)
//   返事  u32 magic = 0x52445541 ("AUDR")  u32 status  u32 n_notes  u32 n_lat  u32 lat_max_us
//     u32 lat_avg_us  u32 active  u32 score_run  u32 gen_max_us  u32 gen_avg_us  u32 n_kick  u32 reverb
//     gen = KICK 1 回で作るのに掛かった時間。遅れ = 命令を受けてから、輪バッファの残り + FIFO の残量を経て鳴るまで
// -----------------------------------------------------------------------------
#include <zephyr/kernel.h>
#include <openamp/open_amp.h>
#include <string.h>

#include "synth.h"
#include "r2r_shm.h"

#define AUD_ADDR  0x460
#define MAGIC_CMD 0x43445541u
#define MAGIC_RES 0x52445541u
#define TARGET    256   /* 輪バッファにためておく標本 (約 5.2ms) */

struct aud_cmd {
	uint32_t magic, cmd, a, b;
} __packed;

struct aud_res {
	uint32_t magic, status, n_notes, n_lat, lat_max_us, lat_avg_us, active, score_run;
	uint32_t gen_max_us, gen_avg_us, n_kick, reverb;
} __packed;

static struct rpmsg_endpoint aud_ept;
static K_MUTEX_DEFINE(lock);
static K_SEM_DEFINE(kick_sem, 0, 1);
static uint32_t n_kick, gen_max_cyc;
static uint64_t gen_sum_cyc;

/* ---- リバーブ (Freeverb の形。遅延は 44.1kHz 用の値を 48.8kHz に合わせて 1.107 倍) ---- */
#define NCOMB 4
#define NAP   2
static const uint16_t comb_len[NCOMB] = {1724, 1790, 1651, 1574};
static const uint16_t ap_len[NAP] = {616, 249};
static int32_t comb_buf0[1724], comb_buf1[1790], comb_buf2[1651], comb_buf3[1574];
static int32_t ap_buf0[616], ap_buf1[249];
static int32_t *const comb_buf[NCOMB] = {comb_buf0, comb_buf1, comb_buf2, comb_buf3};
static int32_t *const ap_buf[NAP] = {ap_buf0, ap_buf1};
static uint16_t comb_i[NCOMB], ap_i[NAP];
static int32_t comb_lp[NCOMB];   /* 櫛形フィルタの中の 1 次ローパス (高音ほど早く減る = 部屋らしさ) */
static uint32_t reverb = 64;

static int32_t reverb_next(int32_t in)
{
	int32_t x = in >> 3;   /* 入れる量を絞る (櫛形は帰還で最大 6 倍ほどに増える) */
	int32_t wet = 0;

	for (int k = 0; k < NCOMB; k++) {
		int32_t y = comb_buf[k][comb_i[k]];

		comb_lp[k] += (y - comb_lp[k]) * 13 >> 4;            /* 減衰 (damp) 0.2 相当 */
		/* 帰還 0.93。最初は Freeverb に近い 0.84 にしたが、実測で響きが約 0.5 秒で消え、曲の中で聞こえなかった */
		comb_buf[k][comb_i[k]] = x + (comb_lp[k] * 30474 >> 15);
		if (++comb_i[k] == comb_len[k]) {
			comb_i[k] = 0;
		}
		wet += y;
	}
	for (int k = 0; k < NAP; k++) {
		int32_t b = ap_buf[k][ap_i[k]];

		ap_buf[k][ap_i[k]] = wet + (b >> 1);   /* 係数 0.5 */
		wet = b - wet;
		if (++ap_i[k] == ap_len[k]) {
			ap_i[k] = 0;
		}
	}
	return in + (wet * (int32_t)reverb >> 7);   /* 混ぜる量 (最初は wet/4 で小さすぎた) */
}

/* ---- 作るスレッド: KICK のたびに、輪バッファが TARGET になるまで作る ---- */
static void gen_thread(void *p1, void *p2, void *p3)
{
	for (;;) {
		k_sem_take(&kick_sem, K_FOREVER);
		k_mutex_lock(&lock, K_FOREVER);
		uint32_t c0 = k_cycle_get_32();
		uint32_t wr = R2R->wr;
		uint32_t have = wr - R2R->rd;

		if (have < TARGET) {
			synth_measure(have + R2R->fifo_level);   /* 今作る音の前に鳴る標本の数 */
			for (uint32_t k = have; k < TARGET; k++) {
				int32_t v = synth_next();
				/* 量 0 なら残響の計算ごと飛ばす (リバーブの重さを「作る時間」の差で測るため) */
				int32_t s = CLAMP(reverb ? reverb_next(v) : v, -32768, 32767);

				R2R->buf[wr++ & (R2R_RING - 1)] = ((uint32_t)(uint16_t)s << 16) | (uint16_t)s;
			}
			synth_block_end();
			R2R->wr = wr;
		}
		uint32_t c = k_cycle_get_32() - c0;

		n_kick++;
		gen_sum_cyc += c;
		gen_max_cyc = MAX(gen_max_cyc, c);
		k_mutex_unlock(&lock);
	}
}
K_THREAD_DEFINE(gen_tid, 1024, gen_thread, NULL, NULL, NULL, 2, 0, 0);

/* main.c の r2r_cb (割り込みの中) から: R5_0 が輪バッファを読んだ */
void r51_audio_kick(void)
{
	k_sem_give(&kick_sem);
}

static uint32_t cyc_us(uint64_t c)
{
	return (uint32_t)(c * 1000000U / sys_clock_hw_cycles_per_sec());
}

static int aud_cb(struct rpmsg_endpoint *e, void *data, size_t len, uint32_t src, void *priv)
{
	const struct aud_cmd *c = data;
	struct aud_res r = {.magic = MAGIC_RES};

	k_mutex_lock(&lock, K_FOREVER);
	if (len != sizeof(*c) || c->magic != MAGIC_CMD) {
		r.status = 2;
	} else {
		switch (c->cmd) {
		case 5:
			break;
		case 6:
			memset(&synth_st, 0, sizeof(synth_st));
			n_kick = 0;
			gen_sum_cyc = 0;
			gen_max_cyc = 0;
			break;
		case 9:
			synth_note(c->a & 0x7F, c->b & 0xFFFF, (c->b >> 16) & 0x7F);
			break;
		case 10:
			synth_wave(c->a);
			break;
		case 11:
			r.status = synth_score_add(c->a, c->b & 0x7F, c->b >> 16, (c->b >> 8) & 0x7F) ? 2 : 0;
			break;
		case 12:
			if (c->a) {
				synth_score_start();
			} else {
				synth_score_clear();
			}
			break;
		case 14:
			reverb = MIN(c->a, 255);
			break;
		default:
			r.status = 2;
		}
	}
	r.n_notes = synth_st.n_notes;
	r.n_lat = synth_st.n_lat;
	r.lat_max_us = synth_st.lat_max_us;
	r.lat_avg_us = synth_st.n_lat ? (uint32_t)(synth_st.lat_sum_us / synth_st.n_lat) : 0;
	r.active = synth_active();
	r.score_run = synth_score_running();
	r.gen_max_us = cyc_us(gen_max_cyc);
	r.gen_avg_us = n_kick ? cyc_us(gen_sum_cyc / n_kick) : 0;
	r.n_kick = n_kick;
	r.reverb = reverb;
	k_mutex_unlock(&lock);
	rpmsg_send(e, &r, sizeof(r));
	return RPMSG_SUCCESS;
}

int r51_audio_init(struct rpmsg_device *rpdev)
{
	synth_init();
	R2R->wr = 0;
	R2R->rd = 0;
	R2R->fifo_level = 0;
	R2R->magic = R2R_MAGIC;   /* R5_0 はこれを見てから分業を始める */
	return rpmsg_create_ept(&aud_ept, rpdev, "rpmsg-raw", AUD_ADDR, RPMSG_ADDR_ANY, aud_cb, NULL);
}
