/* tools/gen_parts_c.py が作る。手で直さない */
#ifndef PARTS_DATA_H
#define PARTS_DATA_H

#define NPARTS 271

typedef struct {
    unsigned char typ;      /* 種類 (pprog の番号) */
    unsigned char glitter;  /* ラメ (枠を広く取る pad=2.6) */
    unsigned char premul;   /* ラメ・気泡は色がプリマルチプライド */
    unsigned char col[3];   /* 色 0〜255 */
    double x, y, z, r, rot, seed;
} Part;

extern const Part parts[NPARTS];
extern const unsigned int parts_check[NPARTS * 24];

#endif
