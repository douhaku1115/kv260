// -----------------------------------------------------------------------------
// synth.c -- R5 で音を作る (音源ファイルなし)。audio_rpmsg.c の書き足しスレッドから呼ばれる
//
//   Linux は「音の高さ・長さ・強さ」だけを送る。R5 が 1 標本ずつ波形を計算して PL の FIFO に書く。
//     - 同時に 8 音。波形は 正弦 / 矩形 / のこぎり / 三角
//     - 高さは位相 (32 ビット) を毎標本 inc ずつ足すだけ (足し算があふれて 1 周する = 1 周期)
//     - 音の形 (包絡): 2ms で立ち上がる → 長さの間はゆっくり減る → 長さが過ぎたら速く消える
//     - 楽譜: (時刻, 音) の列をためておき、標本の数で時刻を数えて鳴らす。テンポは R5 の
//       標本数だけで決まるので、Linux の負荷に左右されない
//   計算は整数だけ (浮動小数点は起動時の表作りだけ)。正弦の表は BTCM (変数領域) に置く
// -----------------------------------------------------------------------------
#include <zephyr/kernel.h>
#include <zephyr/sys/sys_io.h>
#include "synth.h"

#define FS        48828.125f   /* 12.5MHz / 256 */
#define NVOICE    8
#define ATTACK    98           /* 立ち上がり 約 2ms (標本) */
#define ENV_MAX   (1 << 24)    /* 包絡の最大 (Q24) */
#define ENV_OFF   (1 << 12)    /* ここまで減ったら音を止める */
#define SCORE_MAX 256

struct voice {
	uint32_t phase, inc;
	int32_t env, peak;     /* Q24 */
	uint32_t age;          /* 鳴り始めてからの標本数 */
	uint32_t len;          /* この標本数を過ぎたら速く消す */
	uint32_t t_rx;         /* 命令を受けた時刻 (サイクル)。最初に書いた時に遅れを測る。0 = 測定済み */
	bool on;
};

struct ev {
	uint32_t t;            /* 鳴らす時刻 (標本) */
	uint8_t note, vel;
	uint16_t len_ms;
};

static struct voice v[NVOICE];
static int16_t sine[256];
static uint32_t inc12[12];     /* MIDI 120〜131 (C9〜B9) の inc。低い音は右シフトで作る */
static uint8_t wave;           /* 0 正弦 1 矩形 2 のこぎり 3 三角 */

static struct ev score[SCORE_MAX];
static uint32_t n_score, score_pos;
static bool score_run;
static uint32_t clk;           /* 標本の時計 (楽譜用) */

struct synth_stats synth_st;

void synth_init(void)
{
	/* 正弦の表: 単位円を 2π/256 ずつ回す (sin/cos を使わずに済む) */
	float x = 1.0f, y = 0.0f;
	const float c = 0.99969881869620425f, s = 0.024541228522912288f;

	for (int i = 0; i < 256; i++) {
		sine[i] = (int16_t)(y * 32767.0f);
		float nx = x * c - y * s;

		y = x * s + y * c;
		x = nx;
	}
	/* 半音ずつ 2^(1/12) 倍。MIDI 120 (C9) = 440 × 2^(51/12) ≒ 8372.018Hz */
	float f = 8372.018f;

	for (int k = 0; k < 12; k++) {
		inc12[k] = (uint32_t)(f / FS * 4294967296.0f);
		f *= 1.0594630943592953f;
	}
}

static uint32_t note_inc(uint8_t n)
{
	if (n > 131) {
		n = 131;
	}
	/* 同じ音名の C9〜B9 から、オクターブの差だけ右シフト (1 オクターブ下 = 周波数半分) */
	return inc12[n % 12] >> ((120 + n % 12 - n) / 12);
}

void synth_wave(uint8_t w)
{
	wave = w & 3;
}

/* measure: Linux からの命令なら遅れを測る (楽譜の音は測らない) */
static void note_start(uint8_t note, uint16_t len_ms, uint8_t vel, bool measure)
{
	/* 空いている声を使う。なければ一番小さくなった声を奪う */
	int pick = 0;

	for (int i = 0; i < NVOICE; i++) {
		if (!v[i].on) {
			pick = i;
			break;
		}
		if (v[i].env < v[pick].env) {
			pick = i;
		}
	}
	struct voice *p = &v[pick];

	p->phase = 0;
	p->inc = note_inc(note);
	p->peak = (int32_t)((uint32_t)ENV_MAX / 127 * MIN(vel, 127));
	p->env = 0;
	p->age = 0;
	p->len = (uint32_t)len_ms * 48828U / 1000U;
	p->t_rx = measure ? (k_cycle_get_32() | 1) : 0;
	p->on = true;
	synth_st.n_notes++;
}

void synth_note(uint8_t note, uint16_t len_ms, uint8_t vel)
{
	note_start(note, len_ms, vel, true);
}

void synth_score_clear(void)
{
	n_score = 0;
	score_run = false;
}

int synth_score_add(uint32_t t_ms, uint8_t note, uint16_t len_ms, uint8_t vel)
{
	if (n_score >= SCORE_MAX) {
		return -1;
	}
	score[n_score++] = (struct ev){(uint32_t)((uint64_t)t_ms * 48828U / 1000U), note, vel, len_ms};
	return 0;
}

void synth_score_start(void)
{
	/* 時刻順に並べる (挿入ソート。同時刻は入れた順のまま)。synth_next は先頭から順に「時刻が来たか」を
	 * 見るので、並んでいないと後ろに入れた音 (例: メロディの後にまとめて入れた低音) が全部最後に
	 * 一斉に鳴ってしまう (段3〜段5 のきらきら星で最後が爆発音になっていた原因)
	 */
	for (uint32_t i = 1; i < n_score; i++) {
		struct ev e = score[i];
		uint32_t j = i;

		while (j > 0 && score[j - 1].t > e.t) {
			score[j] = score[j - 1];
			j--;
		}
		score[j] = e;
	}
	clk = 0;
	score_pos = 0;
	score_run = n_score > 0;
}

bool synth_score_running(void)
{
	return score_run;
}

uint32_t synth_active(void)
{
	uint32_t n = 0;

	for (int i = 0; i < NVOICE; i++) {
		n += v[i].on;
	}
	return n;
}

static int32_t osc(uint32_t ph)
{
	switch (wave) {
	case 0:
		return sine[ph >> 24];
	case 1:
		return (ph & 0x80000000u) ? -24000 : 24000;   /* 矩形は耳に強いので少し小さく */
	case 2:
		return (int32_t)(ph >> 16) - 32768;
	default: {
		/* 0〜65535。段3〜段5 は ph >> 15 (0〜131071) と誤っていて、波が約 5 倍に振れて割れていた */
		int32_t t = (int32_t)(ph >> 16);

		return t < 32768 ? t * 2 - 32768 : 32767 - (t - 32768) * 2;
	}
	}
}

/* 遅れを測る (1 区切りの頭で 1 回)。level = 今作る標本が鳴るまでに先に鳴る標本の数
 * 遅れ = 命令を受けてから作り始めるまで + level 標本ぶん (R5_0 では FIFO の残量、R5_1 では
 * 輪バッファの残り + FIFO の残量)
 */
void synth_measure(uint32_t level)
{
	uint32_t now = k_cycle_get_32();

	for (int i = 0; i < NVOICE; i++) {
		if (v[i].on && v[i].t_rx) {
			uint32_t us = (uint32_t)((uint64_t)(now - v[i].t_rx) * 1000000U /
						 sys_clock_hw_cycles_per_sec()) +
				      (uint32_t)((uint64_t)level * 1000000U / 48828U);

			synth_st.lat_max_us = MAX(synth_st.lat_max_us, us);
			synth_st.lat_sum_us += us;
			synth_st.n_lat++;
			v[i].t_rx = 0;
		}
	}
}

/* 1 標本作る (全部の声を足し合わせ、16 ビットに収める) */
int32_t synth_next(void)
{
	/* 楽譜: 時刻が来た音符を鳴らす (標本単位で正確) */
	while (score_run && score_pos < n_score && score[score_pos].t <= clk) {
		struct ev *e = &score[score_pos++];

		note_start(e->note, e->len_ms, e->vel, false);
	}
	clk++;

	int32_t mix = 0;

	for (int i = 0; i < NVOICE; i++) {
		struct voice *p = &v[i];

		if (!p->on) {
			continue;
		}
		if (p->age < ATTACK) {
			p->env = p->peak / ATTACK * (int32_t)(p->age + 1);
		} else if (p->age < p->len) {
			p->env -= p->env >> 13;   /* 長さの間: 時定数 約 168ms でゆっくり減る */
		} else {
			p->env -= p->env >> 8;    /* 長さの後: 時定数 約 5ms で消える */
			if (p->env < ENV_OFF) {
				p->on = false;
				continue;
			}
		}
		p->age++;
		mix += (int32_t)(((int64_t)osc(p->phase) * p->env) >> 26);   /* 1 音で最大 ±8192 */
		p->phase += p->inc;
	}
	return CLAMP(mix, -32768, 32767);
}

/* 1 区切り作り終えたら呼ぶ: 楽譜を最後まで鳴らし、音が全部消えたら終わり */
void synth_block_end(void)
{
	if (score_run && score_pos >= n_score && synth_active() == 0) {
		score_run = false;
	}
}

/* R5_0 用: n 標本を作って PL の FIFO に直接書く。level = 書き始める時点の FIFO の残量 */
void synth_render(uint32_t n, uint32_t level)
{
	synth_measure(level);
	for (uint32_t k = 0; k < n; k++) {
		int32_t s = synth_next();

		/* 左右に同じ値 (モノラル) */
		sys_write32(((uint32_t)(uint16_t)s << 16) | (uint16_t)s, SYNTH_REG_DATA);
	}
	synth_block_end();
}
