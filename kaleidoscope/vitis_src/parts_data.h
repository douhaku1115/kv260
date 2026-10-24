/* tools/gen_parts_c.py が作る。手で直さない */
#ifndef PARTS_DATA_H
#define PARTS_DATA_H

#define NPARTS 2730
#define NKINDS 10       /* 配色エディタの種類の数 (最後の気泡を含む) */
#define KCOLS  8       /* 1 種類あたりの色の数 */

typedef struct {
    unsigned char typ;      /* 種類 (pprog の番号) */
    unsigned char kind;     /* 配色エディタの種類 (gen_parts_c.py の KINDS の番号) */
    unsigned char glitter;  /* ラメ (枠を広く取る pad=2.6) */
    unsigned char premul;   /* ラメ・気泡は色がプリマルチプライド */
    unsigned char col[3];   /* 色 0〜255 */
    double x, y, z, r, rot, seed;
} Part;

extern const Part parts[NPARTS];
extern const unsigned int parts_check[NPARTS * 24];
/* 種類ごとの元の色 {R, G, B, 割合}。割合 0 の色は使わない */
extern const unsigned char kind_orig[NKINDS][KCOLS][4];

#endif
