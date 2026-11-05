/* synth.h -- R5 で音を作る (synth.c)。audio_rpmsg.c から使う */
#ifndef SYNTH_H
#define SYNTH_H

#include <stdbool.h>
#include <stdint.h>

#define SYNTH_REG_DATA 0xA0000000UL   /* PL の FIFO の DATA (audio_rpmsg.c の REG_DATA と同じ) */

struct synth_stats {
	uint32_t n_notes;      /* 鳴らした音の数 (楽譜の音も含む) */
	uint32_t n_lat;        /* 遅れを測った回数 (Linux からの音だけ) */
	uint32_t lat_max_us;   /* 命令を受けてから音が出るまでの最長 */
	uint64_t lat_sum_us;
};
extern struct synth_stats synth_st;

void synth_init(void);
void synth_wave(uint8_t w);
void synth_set_fs(uint32_t hz);   /* 標本の速さ: I2S 48828 / HDMI 48000 */
uint32_t synth_get_fs(void);
void synth_note(uint8_t note, uint16_t len_ms, uint8_t vel);
void synth_score_clear(void);
int synth_score_add(uint32_t t_ms, uint8_t note, uint16_t len_ms, uint8_t vel);
void synth_score_start(void);
bool synth_score_running(void);
uint32_t synth_active(void);
void synth_render(uint32_t n, uint32_t level);   /* R5_0 用: n 標本を作って FIFO に書く */
/* R5_1 用 (輪バッファに書くとき): 頭で synth_measure、1 標本ずつ synth_next、最後に synth_block_end */
void synth_measure(uint32_t level);
int32_t synth_next(void);
void synth_block_end(void);

#endif
