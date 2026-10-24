#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xparameters.h"
#include <math.h>
#include "xdppsu.h"
#include "xavbuf.h"
#include "xavbuf_clk.h"
#include "xuartps_hw.h"
#include "parts_data.h"     /* ピースの元の値 (段5d-7。毎フレーム表を作って PL へ書く) */
#include "xiltimer.h"       /* XTime_GetTime。物理演算と表の書き込みの時間を測る (段6) */
#include "ff.h"             /* SD カード (xilffs = FatFs)。配色の保存 */
#include <stdio.h>          /* snprintf */
#include <string.h>
#include "xdppsu.h"
#ifndef SDT
#include "xscugic.h"
#else
#include "xinterrupt_wrap.h"
#endif

/* Base addresses */
#ifndef SDT
#define DPPSU_DEVICE_ID   XPAR_PSU_DP_DEVICE_ID
#define AVBUF_DEVICE_ID   XPAR_PSU_DP_DEVICE_ID
#define INTC_DEVICE_ID    XPAR_SCUGIC_0_DEVICE_ID
#define DPPSU_INTR_ID     151
#define DPPSU_BASEADDR    XPAR_PSU_DP_BASEADDR
#define AVBUF_BASEADDR    XPAR_PSU_DP_BASEADDR
#else
#define DPPSU_BASEADDR    XPAR_XDPPSU_0_BASEADDR
#define AVBUF_BASEADDR    XPAR_XDPPSU_0_BASEADDR
#define INTC_BASEADDR     XPAR_XSCUGIC_0_BASEADDR
#endif

/* ========== 万華鏡のレジスタ (kaleido_axi_slave、0x10 刻み) ========== */
#define KAL_BASE      0xA0000000U
#define KAL_CTRL      (KAL_BASE + 0x000)   /* bit0 = 2枚鏡 */
#define KAL_KX        (KAL_BASE + 0x010)   /* 2^26 / (2*720*focal) */
#define KAL_Z_MIRROR  (KAL_BASE + 0x020)   /* Q16 */
#define KAL_REMAIN0   (KAL_BASE + 0x030)   /* Q14 */
#define KAL_INV_TR    (KAL_BASE + 0x040)   /* Q16 */
#define KAL_COS_T     (KAL_BASE + 0x050)   /* Q15 */
#define KAL_SIN_T     (KAL_BASE + 0x060)   /* Q15 */
#define KAL_WALL(w,i) (KAL_BASE + 0x070 + ((w)*3 + (i))*0x10)   /* nx,ny,wd */
#define KAL_VERT(v,i) (KAL_BASE + 0x100 + ((v)*2 + (i))*0x10)   /* x,y */
#define KAL_COMMIT    (KAL_BASE + 0x160)
#define KAL_FRAME_CNT (KAL_BASE + 0x170)
/* ピースの表の書き込みと描き直し (段5d-7) */
#define KAL_CELL_CTRL (KAL_BASE + 0x180)   /* 2 を書くと表の番地が 0 に戻る */
#define KAL_CELL_DATA (KAL_BASE + 0x190)   /* 書くと表の今の番地に入り、番地が1進む */
#define KAL_DRAW_REQ  (KAL_BASE + 0x1A0)   /* 書くと描き直す。読むと bit0 = 描き直しの途中 */
/* きらめき層 (rtl/sparkle.v)。画面の画素の細かさで光る点を足す。模様を拡大しても点は細かいまま
 * SPK_CTRL: bit0 = 有効, bit3:1 = lv (格子の細かさ), bit11:4 = dens (点がある格子の割合/256)
 * SPK_K   : 点の大きさの係数 (画面 1 画素ぶんの格子の大きさから決める。SpkSet を見る)
 * SPK_GAIN: bit7:0 = base (いつもの明るさ/128), bit15:8 = flash (光ったときの上乗せ/128)
 * SPK_TIME: bit7:0 = 時刻 (256 で 1 周)。毎フレーム書く */
#define KAL_SPK_CTRL  (KAL_BASE + 0x1B0)
#define KAL_SPK_K     (KAL_BASE + 0x1C0)
#define KAL_SPK_GAIN  (KAL_BASE + 0x1D0)
#define KAL_SPK_TIME  (KAL_BASE + 0x1E0)
/* 点の色の表 16 個 {R,G,B} (段7b)。点ごとにハッシュで 1 つ選ばれる。
 * PS は配色エディタの SPARK の 8 色を、割合に応じて 16 個へ振り分けて書く (SpkColors) */
#define KAL_SPK_COL(i) (KAL_BASE + 0x1F0 + (i)*0x10)
#define SPK_NCOL      16
#define SPK_GAP_PX    7.0     /* 点と点の間隔のめやす [画面の画素] */
#define SPK_BASE      26      /* 明るさ 100% のときの base (0.2 * 128) */
#define SPK_FLASH     205     /* 明るさ 100% のときの flash (1.6 * 128) */
#define SPK_SPEED     2.0     /* 光る速さ [rad/s] */
/* 量・明るさ・大きさ。配色エディタで SPARK を選んで u j / i k / o l で変える */
static int spk_amount = 45;   /* 点がある格子の割合 [%] 0〜100 */
static int spk_bright = 100;  /* 明るさ [%] 0〜200 */
static int spk_size   = 75;   /* 点の半径 [画面の画素 x100] 50〜200。50 未満は k が 16bit をあふれる */
#define CELL_SEL_TABLE 2
#define PIECE_WORDS    24
/* 画面に出す文字。1 ワードに 4 文字、下位バイトが左。32桁 x 8行 = 64 ワード */
#define KAL_TEXT(i)   (KAL_BASE + 0x400 + (i)*0x10)
#define TXT_COLS      32
#define TXT_ROWS      8

/* KV260 の USB-UART は psu_uart_1 (0xFF010000)。UART_0 ではない。
   xil_printf の出力先と同じハードだが、RX は直接レジスタで読む。 */
#define UART_BASE  0xFF010000U

/* 筒の寸法 (cm)。参照実装と同じ */
#define TUBE_R    2.25f
#define Z_MIRROR  0.3f
#define Z_CELL    12.2f
#define MIRROR_R  2.05f

/* 設定。シリアルのキー操作 (HandleKey) で変わる */
static int   set_points     = 8;      /* 3〜12 */
static int   set_mirror2    = 0;      /* 0 = 3枚鏡, 1 = 2枚鏡 */
static float set_zoom       = 1.0f;   /* 0.5〜2.5 */
static float set_autorotate = 0.35f;  /* 0〜1。参照実装の既定値 */
/* 往復モード (r キー)。set_rev 秒ごとに自動回転の向きを反転する (0 = 切)。
 * 目標の速さの符号を変えるだけで、筒は StepSim の式で滑らかに減速して逆へ回り出し、
 * 油は粘りで遅れて付いてくるので渦ができる */
static int    set_rev     = 0;        /* 0 / 5 / 10 / 20 [秒] */
static double sim_rev_t   = 0.0;      /* 今の向きになってからの時間 */
static double sim_rev_dir = 1.0;      /* +1 / -1 */
/* おまかせモード (o キー): set_auto 秒ごとに SD の KPAL1〜4 を順に読む。0 = 切 */
static int    set_auto  = 0;
static double auto_t    = 0.0;        /* 今の模様になってからの時間 */
static int    auto_slot = 1;          /* 今読んでいる番号。起動時は KPAL1 を読むので 1 */
static int   set_text_on    = 1;      /* 操作一覧をモニターに出すか */
static int   txt_keys       = 0;      /* モニターの文字をキーボードの並びの絵にするか (h / エディタでは /) */
static float set_viscosity  = 0.5f;   /* 粘り 0〜1。参照実装の既定値 (まだキーは無い) */

/* 筒の回転角 [rad]。PL の COS_T/SIN_T (セルの回転) と物理演算の重力の向きの両方に使う */
static double sim_tube_angle = 0.0;

/* ========== 色の組み合わせ (c キーで切り替え) ==========
 * 下の palettes[] は「組み込みの組」。c キーで選ぶと、今の配色 cset[] (種類ごとに 8 色と割合)
 * へ写す。ピースの色は cset[] から、ピースの番号で色を選び、種 (seed) で明るさを
 * 0.88〜1.08 倍ばらつかせる (kv_cell.py の spawn() と同じ幅)。表に入る色が変わるだけなので
 * 合成は要らない。0 番 ORIGINAL は生成したときの色 (tools/kv_cell.py の COLORS。
 * parts_data.c の kind_orig[]) で、色の選ばれ方は生成時と違うが割合は同じ。
 * cset[] は p キーの配色エディタで直せて、SD カードに 4 つまで保存できる (下の「配色エディタ」)。
 * ラメは粒の色がそのまま光の色になるので、白・金・銀などの別の並びを持つ。
 * ★ ビーズ (小ビーズも) にも明るい並びを別に持たせる。宝石色をそのまま当てたら
 *   「細かな粒が無い」と言われた。元の色ではビーズに白と黄色が入っていて、暗い地の上で
 *   それが細かい粒として光っていた。濃い色の小さい粒は地に沈んで見えなくなる */
typedef struct {
    const char *name;           /* 画面に出す名前 (英字 8 文字まで) */
    u8 solid[6][3];             /* ガラス・石・棒など */
    u8 bead[4][3];              /* ビーズ・小ビーズ (明るい色) */
    u8 glit[4][3];              /* ラメ */
} Palette;

static const Palette palettes[] = {
    { "ORIGINAL", {{0}}, {{0}}, {{0}} },
    { "JEWEL",
      {{220, 20, 60}, {15, 82, 186}, {0, 155, 119}, {255, 176, 0}, {153, 102, 204}, {255, 200, 124}},
      {{255, 255, 255}, {255, 215, 120}, {255, 150, 170}, {150, 220, 255}},
      {{255, 255, 255}, {255, 215, 120}, {220, 225, 235}, {255, 190, 220}} },
    { "RAINBOW",
      {{255, 40, 40}, {255, 140, 0}, {255, 230, 0}, {40, 200, 60}, {30, 90, 255}, {170, 60, 255}},
      {{255, 255, 255}, {255, 240, 120}, {140, 255, 160}, {150, 200, 255}},
      {{255, 255, 255}, {255, 240, 200}, {200, 230, 255}, {255, 200, 255}} },
    { "PASTEL",
      {{255, 179, 186}, {255, 223, 186}, {255, 255, 186}, {186, 255, 201}, {186, 225, 255}, {220, 190, 255}},
      {{255, 255, 255}, {255, 240, 245}, {240, 250, 255}, {255, 250, 220}},
      {{255, 255, 255}, {255, 240, 245}, {240, 250, 255}, {255, 250, 230}} },
    { "WARM",
      {{255, 60, 30}, {255, 120, 0}, {255, 190, 40}, {200, 30, 80}, {255, 220, 150}, {180, 60, 20}},
      {{255, 255, 255}, {255, 225, 130}, {255, 190, 140}, {255, 240, 200}},
      {{255, 215, 120}, {255, 255, 255}, {255, 180, 120}, {255, 230, 180}} },
    { "BLUE",
      {{20, 60, 220}, {40, 140, 255}, {0, 200, 230}, {90, 60, 220}, {170, 210, 255}, {30, 30, 140}},
      {{255, 255, 255}, {190, 230, 255}, {160, 255, 250}, {210, 200, 255}},
      {{255, 255, 255}, {200, 230, 255}, {180, 160, 255}, {220, 240, 255}} },
};
#define NPALETTES ((int)(sizeof(palettes) / sizeof(palettes[0])))
static int set_palette = 0;

/* 今の配色。種類 (parts_data.h の kind、gen_parts_c.py の KINDS の順) ごとに 8 色と割合 [%]。
 * 割合 0 の色は使わない。割合の合計は 100 でなくてよい (合計に対する比で選ぶ) */
typedef struct {
    u8 rgb[KCOLS][3];
    u8 rate[KCOLS];
} KindColor;
#define KIND_SPARK    NKINDS           /* きらめき層の点 (ピースではない)。cset[] の最後 */
#define NCSET         (NKINDS + 1)
static KindColor cset[NCSET];
static char      cset_name[12] = "ORIGINAL";      /* 画面に出す名前 (組の名前か SLOTn) */
/* 画面に出す種類の名前 (英字 7 文字まで)。気泡は色を変えないので編集の対象外 */
static const char *const kind_name[NCSET] = {
    "BEAD", "S.BEAD", "GLASS", "GLITTER", "STONE", "HEX", "ROD", "BLOB", "MOON", "BUBBLE", "SPARK"
};
#define KIND_BEAD     0
#define KIND_SBEAD    1
#define KIND_GLITTER  3
#define KIND_BUBBLE   (NKINDS - 1)
#define NKIND_EDIT    (NKINDS - 1)     /* 色を直せるピースの種類の数 (気泡を除く) */
/* 配色エディタで直せるか (気泡だけ除く。SPARK は直せる) */
#define KIND_EDITABLE(k)  ((k) != KIND_BUBBLE)

/* 構成 (t キー / おまかせ): どの種類のピースを出すか。出さないピースは表にも押し合いにも入れない
 * (動きの計算だけは続けるので、また出したときにその場から現れる)。
 * ビットは種類の番号 (BEAD S.BEAD GLASS GLITTER STONE HEX ROD BLOB MOON BUBBLE の順) */
#define KB(k)  (1u << (k))
static const struct { const char *name; const char *jp; u16 mask; } comps[] = {
    { "ALL", "全部",       0x3FF },
    { "GRN", "粒だけ",     KB(0) | KB(1) | KB(3) | KB(9) },           /* ビーズ・小ビーズ・ラメ・気泡 */
    { "GLS", "ガラスと石", 0x3FF & ~(KB(0) | KB(3)) },               /* 粒は小ビーズだけ */
    { "CLM", "ラメなし",   0x3FF & ~KB(3) },
};
#define NCOMPS  ((int)(sizeof(comps) / sizeof(comps[0])))
static int set_comp = 0;
#define PART_SHOWN(i)  ((comps[set_comp].mask >> parts[i].kind) & 1)
static void LoadPreset(int n);
static void SpkColors(void);
static int  SdSave(int slot);
static int  SdLoad(int slot);
static void EditKey(int c);
static void ShowEditHelp(void);
static int  ed_on = 0;                 /* 配色エディタを出しているか (p キー) */
static int  ed_kind = 0;               /* 直している種類 (cset[] の番号。気泡は飛ばす) */
static int  ed_col  = 0;               /* 直している色の番号 0 〜 KCOLS-1 */
static char ed_msg[12] = "";           /* 保存した・SD が無い などをエディタの 1 行目に出す */
/* 300 フレームごとの描き直し回数・物理演算の時間をシリアルに出すか。
 * キー一覧が流れて読めなくなるので普段は 0。測るときだけ 1 にする */
#define SHOW_STATS 0
/* 物理演算の内訳の時間 (移動・押し合い・壁)。300 フレームぶん足して平均を出す */
static XTime  t_move_sum, t_push_sum, t_wall_sum;
static u32    n_pair_sum, n_hit_sum;   /* 調べた組 / 実際に重なっていた組 */

typedef enum { LANE_COUNT_1 = 1, LANE_COUNT_2 = 2 } LaneCount_t;
typedef enum { LINK_RATE_162 = 0x06, LINK_RATE_270 = 0x0A, LINK_RATE_540 = 0x14 } LinkRate_t;

static XDpPsu DpPsu;
static XAVBuf AVBuf;

/* Forward declarations */
static int InitDP(void);
static void RunDP(void);
static void SetupVideoStream(void);
static u32 TrainLink(void);
static void KalSetGeometry(void);
static void SpkSet(void);
static void SpkTick(void);
static int  uart_getchar_nb(void);
static void ShowSettings(void);
static void ShowHelp(void);
static void HandleKey(int c);
static void UpdateText(void);
static void PieceWords(const Part *p, double rot, u32 *w);
static void SelfCheckTable(void);
static void SimInit(void);
static void StepSim(double dt);
static void SimStir(void);
static void SimTurn(double dir);
static void WriteTable(void);
static void AutoNext(void);
static void SimLists(void);

int main(void)
{
    /* キャッシュは有効のまま (BSP の起動処理が有効にする)。
     * 段6 まではDPDMA の手本どおり両方切っていたが、物理演算が 1 フレーム 24ms かかった。
     * 切る必要は無い:
     *   - 映像は PL からの Live Video で、DDR の画像バッファを使わない
     *   - PL のレジスタ 0x80000000〜0xBFFFFFFF は MMU の表 (translation_table.S) で
     *     Strongly Ordered なので、D キャッシュを入れても AXI は素通し */

    xil_printf("KV260 Kaleidoscope Start\r\n");

    if (InitDP() != XST_SUCCESS) {
        xil_printf("DP init failed\r\n");
        return XST_FAILURE;
    }

    sleep(1);
    RunDP();

    /* HPD 割り込みは設定しない。
       設定すると "Video stream started" の直後で止まり、映像が出ない
       （2026-09-18 実機で確認。ログが "Running." まで進まなかった）。
       動作実績のある kv260_pong も割り込みを一切設定していない。
       モニタの抜き差しに追従しなくなるが、表示には影響しない。 */
    /* ========== ピースの表 (段5d-7) ==========
     * 段5d-6 までは起動時に油の地を 65536 語流し込んでいた (67ms)。
     * 段5d-7 から油の地は PL の ROM にあり、PL が描き直しのたびに写すので
     * 流し込みは要らない。PS は毎フレーム「ピースの表」(271 個 x 24 語) を
     * 書いて DRAW_REQ を書くだけ。
     * まず PS の計算が焼き込みの表と同じになるかを確かめる (自己検査)。 */
    SelfCheckTable();
    SimInit();                   /* 物理演算の状態を元の値から作る (段6) */

    /* 配色。SD カードに KPAL1.TXT があればそれで始める。無ければ ORIGINAL */
    LoadPreset(0);
    {
        const int r = SdLoad(1);
        if (r > 0) xil_printf("SD: KPAL1.TXT を読み込んだ (%d 種類)\r\n", r);
        else       xil_printf("SD: KPAL1.TXT なし (%d)。配色は ORIGINAL\r\n", r);
    }

    /* ========== 万華鏡のパラメータを書く ========== */
    KalSetGeometry();
    UpdateText();                /* 操作一覧をモニターに出す (i キーで消せる) */
    xil_printf("Running. points=%d mirror=%d\r\n", set_points, set_mirror2 ? 2 : 3);

    /* ========== AXI の疎通確認 ==========
     * 書いた値が読み返せるか、PL のフレーム数が進んでいるかを見る。
     * 回らないときは、ここの出力で原因が分かる:
     *   KX が 109655 でない      → 書き込みが届いていない
     *   FRAME_CNT が 0 のまま    → frame_start が立っていない、か読み出し経路
     *   FRAME_CNT が進む         → PL 側は正常。待ちループ以外が原因
     */
    xil_printf("--- AXI diag ---\r\n");
    for (int i = 0; i < 5; i++) {
        xil_printf("  FRAME_CNT=%u  KX=%u  NX0=%u  COS=%u\r\n",
                   (unsigned)Xil_In32(KAL_FRAME_CNT),
                   (unsigned)Xil_In32(KAL_KX),
                   (unsigned)Xil_In32(KAL_WALL(0,0)),
                   (unsigned)Xil_In32(KAL_COS_T));
        usleep(100000);          /* 100ms = 6 フレームぶん */
    }
    xil_printf("--- AXI diag done ---\r\n");
    ShowHelp();

    /* ========== 毎フレーム、物理演算を進めて筒の回転角を PL へ渡す ========== */
    const double dt = 1.0 / 60.0;
    u32 last = Xil_In32(KAL_FRAME_CNT);
    int  use_frame_cnt = 1;
    int  reported = 0;

    /* 描き直しの回数を数える (5 秒ごとにシリアルへ。60 なら毎フレーム) */
    u32 frames = 0, redraws = 0, rep_frames = 0, rep_redraws = 0;
    /* 物理演算と表の書き込みにかかった時間の最大 (5 秒ごとにシリアルへ) */
    XTime t_sim_max = 0, t_tbl_max = 0;

    while (1) {
        /* PL が数えたフレーム数が進むまで待つ (映像と歩調を合わせる)。
           進まない場合は待ち続けずに時間待ちへ切り替える。 */
        if (use_frame_cnt) {
            u32 now;
            int guard = 0;
            do { now = Xil_In32(KAL_FRAME_CNT); } while (now == last && ++guard < 2000000);
            if (guard >= 2000000) {
                if (!reported) { xil_printf("FRAME_CNT が進まない。時間待ちに切替\r\n"); reported = 1; }
                use_frame_cnt = 0;
            }
            last = now;
        } else {
            usleep(16667);       /* 60fps 相当 */
        }

        /* シリアルのキー入力を全部吸い上げる */
        int c;
        while ((c = uart_getchar_nb()) >= 0) HandleKey(c);

        /* ========== ピースを描き直す (段5d-7) ==========
         * PL が前の描き直しを終えて面を入れ替えていれば (bit0 = 0)、
         * 新しい表を書いて次の描き直しを頼む。
         * ★ bit0 が 1 の間に表を書くと、描きかけに新しい表が混ざる。
         * ★ 物理演算より先に頼む (表は前のフレームの位置)。ピース 2038 個だと PL の
         *   描き直しに 30ms 余りかかり、物理演算 (10ms) の後に頼むと 3 フレームに 1 回に落ちた */
        XTime t0, t1, t2;
        frames++;
        if ((Xil_In32(KAL_DRAW_REQ) & 1) == 0) {
            XTime_GetTime(&t1);
            WriteTable();
            Xil_Out32(KAL_DRAW_REQ, 1);
            XTime_GetTime(&t2);
            if (t2 - t1 > t_tbl_max) t_tbl_max = t2 - t1;
            redraws++;
        }

        /* 参照実装と同じく 1 フレームを半分ずつ 2 回進める */
        XTime_GetTime(&t0);
        StepSim(dt / 2);
        StepSim(dt / 2);
        XTime_GetTime(&t1);
        if (t1 - t0 > t_sim_max) t_sim_max = t1 - t0;

        /* おまかせモード。配色エディタを開いている間は切り替えない (直している配色が消える) */
        if (set_auto > 0 && !ed_on) {
            auto_t += dt;
            if (auto_t >= set_auto) { auto_t = 0.0;  AutoNext(); }
        }

        Xil_Out32(KAL_COS_T, (u32)(s32)(cos(sim_tube_angle) * 32768.0));
        Xil_Out32(KAL_SIN_T, (u32)(s32)(sin(sim_tube_angle) * 32768.0));
        SpkTick();
        Xil_Out32(KAL_COMMIT, 1);     /* ここまでの値を次のフレーム先頭で一括反映 */
        if (frames - rep_frames >= 300) {
          if (SHOW_STATS) {
            xil_printf("描き直し %u 回 / %u フレーム  物理 最大 %u us  表 最大 %u us\r\n",
                       (unsigned)(redraws - rep_redraws), (unsigned)(frames - rep_frames),
                       (unsigned)(t_sim_max * 1000000 / COUNTS_PER_SECOND),
                       (unsigned)(t_tbl_max * 1000000 / COUNTS_PER_SECOND));
            /* 1 フレームあたりの平均 (StepSim 2 回ぶん) */
            const u32 nf = frames - rep_frames;
            xil_printf("  内訳 平均: 移動 %u us  押し合い %u us  壁 %u us  組 %u  重なり %u\r\n",
                       (unsigned)(t_move_sum * 1000000 / COUNTS_PER_SECOND / nf),
                       (unsigned)(t_push_sum * 1000000 / COUNTS_PER_SECOND / nf),
                       (unsigned)(t_wall_sum * 1000000 / COUNTS_PER_SECOND / nf),
                       (unsigned)(n_pair_sum / nf), (unsigned)(n_hit_sum / nf));
          }
            t_move_sum = t_push_sum = t_wall_sum = 0;
            n_pair_sum = n_hit_sum = 0;
            rep_frames = frames;
            rep_redraws = redraws;
            t_sim_max = t_tbl_max = 0;
        }
    }
    return 0;
}

/* ========== シリアルからの操作 ==========
 * KV260 にはマウスもキーボードも標準では無い。USB ホストをベアメタルで
 * 載せるのは大仕事なので、既につながっている USB-UART を入力に使う。
 * Tera Term でキーを打つと設定が変わる。
 *
 * 【まだ効かないもの】
 *   遠くの暗さ (fade) — 減光表が $readmemh の ROM なので実行中に変えられない。
 *                       AXI から書ける形にする改造が要る (要・再合成)
 *   色テーマ / ピースの個数 / 粘り / かき混ぜる — 段5c・段6 でピースと
 *                       物理演算を実装してから
 */
static int uart_getchar_nb(void)
{
    u32 sr = XUartPs_ReadReg(UART_BASE, XUARTPS_SR_OFFSET);
    if (sr & XUARTPS_SR_RXEMPTY) return -1;
    return (int)(XUartPs_ReadReg(UART_BASE, XUARTPS_FIFO_OFFSET) & 0xFF);
}

/* ★ PL の scope_pipe の KX_SH と必ず合わせること ★
 *
 *   KX_SH = 12 のビットストリーム:  KX_NUM = 2^27,  zoom 下限 0.85
 *   KX_SH = 11 のビットストリーム:  KX_NUM = 2^26,  zoom 下限 0.50
 *
 * KX = KX_NUM/(1440*0.85*zoom) が 18bit (131071) を超えると模様が壊れる。
 * KX_SH=12 だと境界が zoom=0.837 で、実機でちょうどそこで崩れるのを確認した。
 * 合わせ忘れると画角がちょうど2倍ずれる。 */
#define KX_NUM    67108864.0f    /* 2^26  … KX_SH = 11 用 (2026-09-19 以降) */
#define ZOOM_MIN  0.50f
#define ZOOM_MAX  2.50f

/* 1行だけ出す。1キーごとに何行も出すと 115200bps では十数ミリ秒かかり、
   フレーム同期を圧迫して取りこぼしの原因になる。 */
static void ShowSettings(void)
{
    xil_printf("ポイント %2d  ミラー %d  大きさ %3d  回転 %3d  往復 %2d秒  粘り %3d  色 %s  構成 %s  おまかせ %3d秒%s\r\n",
               set_points, set_mirror2 ? 2 : 3,
               (int)(set_zoom * 100.0f + 0.5f),
               (int)(set_autorotate * 100.0f + 0.5f),
               set_rev,
               (int)(set_viscosity * 100.0f + 0.5f),
               cset_name, comps[set_comp].jp, set_auto,
               (set_points > 10) ? "  ※11以上は反射19回。K=16では外側が崩れる" : "");
}

/* キーの一覧はキーボードの並びで出す (どのキーがどこにあるか分かるように)。
 * Tera Term の横幅 80 桁に収める (日本語は 1 文字 2 桁)。空いているキーは空白で詰める */
static void ShowHelp(void)
{
    xil_printf("\r\n\r\n\r\n--- キー (Shift 不要。キーボードの並び) ---\r\n");   /* 空行 2 つで流れる表示と区切る */
    xil_printf("                                                        [0]初期設定\r\n");
    xil_printf(" [q]ポイント- [w]ポイント+ [e]混ぜる [r]往復 [t]構成 [i]一覧 [o]自動 [p]配色\r\n");
    xil_printf("  [a]小さく [s]大きく                  [h]この一覧 [j]左回し   [l]右回し\r\n");
    xil_printf("   [z]回転遅く [x]回転速く [c]色の組 [v]サラサラ [b]ネバネバ   [m]鏡2/3枚\r\n");
    xil_printf("  r 往復: 切→5秒→10秒→20秒→切   c 色の組: %d 通り   j l は押している間だけ\r\n",
               NPALETTES);
    xil_printf("  t 構成: 全部→粒だけ→ガラスと石→ラメなし   i 画面の一覧を出す/消す\r\n");
    xil_printf("  o 自動 (おまかせ): 切→30秒→60秒→120秒→切。その間隔で KPAL1〜4 の設定を順に読み、\r\n");
    xil_printf("    色の組と構成も替える (大きさは今のまま)\r\n");
    xil_printf("  p 配色エディタ (中で / を押すとエディタのキーが出る)\r\n");
    xil_printf("  h はモニターの文字もキーの並びの絵にする (もう一度 h で戻る)。絵の略語:\r\n");
    xil_printf("    P±ポイント MX混ぜる RV往復 TX画面一覧 ED配色 Z±大きさ KYこの絵 <<>>手で回す\r\n");
    xil_printf("    S±回転 CL色の組 V±粘り MR鏡 RS初期設定 AU自動 CM構成\r\n");
    ShowSettings();
}

/* キーはすべて Shift 不要のものにしてある。
   JIS 配列だと < > + = はどれも Shift が要って打ちにくい。 */
static void HandleKey(int c)
{
    int geom = 0;      /* 鏡の形か画角が変わったら 1 */

    /* 受け取ったキーをそのまま出す。効かないときに
       「届いていない」のか「届いたが値が端まで来ている」のかを区別するため。 */
    if (c >= 0x20 && c < 0x7F) xil_printf("[%c] ", c);
    else                       xil_printf("[%02x] ", c);

    if (ed_on) { EditKey(c); return; }    /* 配色エディタの中ではキーの意味が変わる */

    switch (c) {
    /* ポイント数 */
    case 'q': case '[': if (set_points > 3)  { set_points--; geom = 1; } break;
    case 'w': case ']': if (set_points < 12) { set_points++; geom = 1; } break;

    /* ミラーの枚数 */
    case 'm': set_mirror2 = !set_mirror2; geom = 1; break;

    /* 模様の大きさ (zoom) */
    case 'a': case '-':
        if (set_zoom > ZOOM_MIN + 0.001f) { set_zoom -= 0.05f; geom = 1; } break;
    case 's': case '+': case '=':
        if (set_zoom < ZOOM_MAX - 0.001f) { set_zoom += 0.05f; geom = 1; } break;

    /* 回転の速さ */
    case 'z': case ',': case '<':
        if (set_autorotate > 0.001f) set_autorotate -= 0.05f; break;
    case 'x': case '.': case '>':
        if (set_autorotate < 0.999f) set_autorotate += 0.05f; break;

    /* 往復モード: 切 → 5 秒 → 10 秒 → 20 秒 → 切 */
    case 'r':
        set_rev = (set_rev == 0) ? 5 : (set_rev == 5) ? 10 : (set_rev == 10) ? 20 : 0;
        sim_rev_t = 0.0;
        if (set_rev == 0) sim_rev_dir = 1.0;   /* 切ったら元の向きに戻す */
        break;

    /* おまかせモード: 切 → 30 秒 → 60 秒 → 120 秒 → 切 */
    case 'o':
        set_auto = (set_auto == 0) ? 30 : (set_auto == 30) ? 60 : (set_auto == 60) ? 120 : 0;
        auto_t = 0.0;
        break;

    /* 構成: 全部 → 粒だけ → ガラスと石 → ラメなし → 全部 */
    case 't': set_comp = (set_comp + 1) % NCOMPS;  SimLists();  break;

    /* 油の粘り (段6) */
    case 'v': if (set_viscosity > 0.001f) set_viscosity -= 0.1f; break;
    case 'b': if (set_viscosity < 0.999f) set_viscosity += 0.1f; break;

    /* かき混ぜる・筒を手で回す (段6)。表示は変わらないので一覧は出し直さない */
    case 'e': SimStir();      xil_printf("かき混ぜた\r\n"); return;
    case 'j': SimTurn(+1.0);  return;
    case 'l': SimTurn(-1.0);  return;

    /* 操作一覧をモニターに出す/消す */
    case 'i': set_text_on = !set_text_on; break;

    /* 色の組み合わせ。次の描き直しから変わる */
    case 'c': LoadPreset((set_palette + 1) % NPALETTES); SpkSet(); break;

    /* 配色エディタを出す */
    case 'p': ed_on = 1; ed_msg[0] = '\0'; txt_keys = 0; UpdateText(); ShowEditHelp(); return;

    case '0':
        set_points = 8; set_mirror2 = 0; set_zoom = 1.0f; set_autorotate = 0.35f;
        set_rev = 0;  sim_rev_t = 0.0;  sim_rev_dir = 1.0;
        set_auto = 0;
        set_comp = 0;  SimLists();
        set_viscosity = 0.5f;  LoadPreset(0);
        spk_amount = 45;  spk_bright = 100;  spk_size = 75;    /* SpkSet は KalSetGeometry から */
        geom = 1;
        break;
    /* シリアルに一覧を出し、モニターの文字もキーの並びの絵と切り替える */
    case 'h': case '?': txt_keys = !txt_keys; UpdateText(); ShowHelp(); return;
    default: xil_printf("(割り当て無し)\r\n"); return;
    }

    if (set_zoom < ZOOM_MIN) set_zoom = ZOOM_MIN;
    if (set_zoom > ZOOM_MAX) set_zoom = ZOOM_MAX;
    if (set_autorotate < 0.0f) set_autorotate = 0.0f;
    if (set_autorotate > 1.0f) set_autorotate = 1.0f;
    if (set_viscosity < 0.0f) set_viscosity = 0.0f;
    if (set_viscosity > 1.0f) set_viscosity = 1.0f;

    if (geom) KalSetGeometry();   /* 鏡の法線・頂点・画角を書き直して COMMIT */
    UpdateText();                 /* 画面の一覧にも新しい値を出す。CTRL を最後に書く */
    ShowSettings();
}

/* ========== ピースの表 (段5d-7) ==========
 * PL の並び替え器が読む 1 個 24 語を、ピースの元の値から作る。
 * tools/gen_pparts.py の piece_words() を一行ずつ写したもの。
 * double で計算する (Python と同じ丸めにするため。A53 は double の演算器を持つ)。
 */
#define CELL_PX 256
#define FRAC_ONE 131072.0      /* S6.17 */

static u32 fx24(double v)
{
    /* Python の round() は偶数丸め。nearbyint も既定の丸めモードでは偶数丸め */
    double n = nearbyint(v * FRAC_ONE);
    if (n >  8388607.0) n =  8388607.0;
    if (n < -8388608.0) n = -8388608.0;
    return ((u32)(s32)n) & 0xFFFFFF;
}

/* ラメのきらめきの時刻 (表の 18 語目、プログラムの time)。
 * 段6 までは 0 のままで、ラメは回転 (rot) が変わったときしか光り方が変わらなかった。
 * WriteTable が毎回 sim_time から作る。
 * ★ プログラムは tt = (seed*0.6+0.3) * time を S6.17 (±64) で扱う前提で、
 *   time は 2π/0.9 (= 6.98) 未満に折り返して渡すこと (tools/piece_isa.py)。
 *   折り返した瞬間に位相が飛ぶが、そのラメが急に光るか消えるだけで目立たない */
#define GLIT_SPEED 2.5      /* きらめきの速さ。1 で参照実装と同じ (1 粒 7〜21 秒に 1 回) */
#define GLIT_WRAP  6.9
static double glit_time = 0.0;

static void PieceWords(const Part *p, double rot, u32 *w)
{
    const double pad = p->glitter ? 2.6 : 1.2;
    const int n = CELL_PX;
    const double r = p->r * (0.85 + 0.3 * p->z);          /* 奥行きで大きさが変わる */
    const double half = r * pad;
    int x0 = (int)floor((p->x - half + 1.0) * 0.5 * n);
    int x1 = (int)ceil ((p->x + half + 1.0) * 0.5 * n);
    int y0 = (int)floor((p->y - half + 1.0) * 0.5 * n);
    int y1 = (int)ceil ((p->y + half + 1.0) * 0.5 * n);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > n) x1 = n;
    if (y1 > n) y1 = n;
    int wdt = x1 - x0;  if (wdt < 8) wdt = 8;               /* 幅は LANES 以上に丸める */
    int hgt = y1 - y0;  if (hgt < 1) hgt = 1;
    if (x0 + wdt > n) x0 = n - wdt;                         /* はみ出したら寄せる */
    if (y0 + hgt > n) y0 = n - hgt;

    const double inv_r = 1.0 / r;
    const double s  = (2.0 / n) * inv_r;
    const double ca = cos(rot), sa = sin(rot);
    const double sx = (x0 + 0.5) / n * 2.0 - 1.0;
    const double sy = (y0 + 0.5) / n * 2.0 - 1.0;
    const double vqx0 = (sx - p->x) * inv_r;
    const double vqy0 = (sy - p->y) * inv_r;
    const double qx0 = ca * vqx0 - sa * vqy0;
    const double qy0 = sa * vqx0 + ca * vqy0;
    const double e     = 0.1 + (0.025 - 0.1) * p->z;
    const double depth = 0.65 + 0.35 * p->z;
    const int front = (p->z >= 0.5) ? 1 : 0;                /* 参照実装と同じく z >= 0.5 が手前層 */

    w[0]  = p->typ;   w[1] = wdt;   w[2] = wdt * hgt;   w[3] = x0;   w[4] = y0;
    w[5]  = fx24(vqx0);   w[6]  = fx24(vqy0);   w[7]  = fx24(qx0);   w[8]  = fx24(qy0);
    w[9]  = fx24(s);      w[10] = fx24(s);
    w[11] = fx24(ca * s); w[12] = fx24(-sa * s); w[13] = fx24(sa * s); w[14] = fx24(ca * s);
    w[15] = fx24(p->seed); w[16] = fx24(e); w[17] = fx24(rot); w[18] = fx24(glit_time);
    w[19] = p->col[0];  w[20] = p->col[1];  w[21] = p->col[2];
    w[22] = fx24(depth);
    w[23] = p->premul | (front << 1);
}

/* 起動時の自己検査: 回転を変えずに作った表が pparts.hex (焼き込みの表) と
 * 1 語も違わないか。PC に C コンパイラが無いので、ここでしか確かめられない。 */
static void SelfCheckTable(void)
{
    u32 w[PIECE_WORDS];
    u32 first_ps = 0;
    int bad = 0, first = -1;
    for (int i = 0; i < NPARTS; i++) {
        PieceWords(&parts[i], parts[i].rot, w);
        for (int k = 0; k < PIECE_WORDS; k++) {
            if (w[k] != parts_check[i * PIECE_WORDS + k]) {
                if (first < 0) { first = i * PIECE_WORDS + k; first_ps = w[k]; }
                bad++;
            }
        }
    }
    xil_printf("表の自己検査: %d 語中 %d 語不一致", NPARTS * PIECE_WORDS, bad);
    if (bad)
        xil_printf(" (最初は %d 語目: PS=%06x 正解=%06x)", first,
                   (unsigned)first_ps, (unsigned)parts_check[first]);
    xil_printf("\r\n");
}

/* ========== 物理演算 (段6) ==========
 * 参照実装の stepSim() (ref/stepSim.js) を一行ずつ写したもの。
 * PS が毎フレーム 271 個を動かし、結果を WriteTable で PL の表へ書く。PL は触らない。
 *
 * 座標はセル (筒の中) の座標。筒が回るとセルごと回るので、画面の下向き
 * (重力) はセルの中では筒の回転角の逆に回る (upInCell)。
 *   - 筒の回転と油の回転の差 wRel が渦を作る (油は粘りに応じて遅れて追従)
 *   - ピースの目標速度 = 渦 + ゆるい対流 + 沈降 + 微小な揺らぎ。速度は指数緩和で追従
 *   - 奥行き z はランダムウォーク (気泡は手前に固定)
 *   - 押し合いは円の衝突を 2 回反復 (ラメは cr=0 で省略)。z が 0.45 以上離れれば重なってよい
 *   - 筒の内壁 (半径 0.985) の外に出たら内側へ戻す
 */
#define TWO_PI_D 6.283185307179586

/* 種類ごとの沈む強さと当たり判定 (tools/piece_table.py の KV_PIECES。番号は kv_cell.py) */
static const double type_sink[9] = {
    /* bead glass glitter hexprism bubble stone rod  blob crescent */
       0.28, 0.15, 0.03,   0.18,    -0.3,  0.34, 0.20, 0.12, 0.10 };
static const double type_cr[9] = {
       1.00, 0.85, 0.00,   0.50,    1.00,  1.00, 0.45, 0.90, 0.70 };
#define TYPE_BEAD    0
#define TYPE_GLITTER 2
#define TYPE_BUBBLE  4

typedef struct {
    double x, y, z, vx, vy, vz, rot, spin, sink, cr;
} SimPart;

static SimPart sp[NPARTS];          /* parts[] と同じ並び */
/* 押し合いに加わるもの (cr > 0) を、マス目に入る「小」と、入らない「大」に分ける。
 * マスの一辺は「小の cr の最大の 2 倍」以上あれば、小どうしは同じマスか隣のマスにしか
 * 当たらない。一辺を cr の最大 (色ガラス 0.042) で決めると粗くなり、
 * 調べる組の 95% が空振りだった (16x16: 41 万組 / 23x23: 23 万組・1 フレーム)。
 * そこで cr の上位約 5% (大、約 50 個) をマス目から外し、別に調べる (tools/cr_stats.py) */
static u16     solid[NPARTS];       /* 小の番号 */
static int     nsolid;
static u16     big[NPARTS];         /* 大の番号 */
static int     nbig;
static float   small_cr_max;        /* 小の cr の最大。大がどこまでのマスを見るかに使う */
/* 押し合いのマス目。筒の中 (-1〜1) を GRID_N x GRID_N に分ける。一辺 2/32 = 0.0625 なので
 * cr が 0.03125 以下のものが小 */
#define GRID_N 32
static double  grid_size;
/* 押し合いに使う値だけをマス目の順に詰めた写し (float)。
 * 段6b で 2038 個にしたとき、sp[] (1 個 80 バイト) を番号でたどる形だと
 * 毎フレーム 32 万組・16ms かかった。詰めて並べると 1 次キャッシュに収まる */
static u16     cell_start[GRID_N * GRID_N + 1];  /* マス c の範囲は cell_start[c]〜[c+1] */
static u16     cell_fill[GRID_N * GRID_N];
static u16     pk_idx[NPARTS];                   /* 詰めた位置 → sp[] の番号 */
static float   pk_x[NPARTS], pk_y[NPARTS], pk_z[NPARTS], pk_cr[NPARTS];
/* 大の写し (並びは big[] と同じ) */
static float   bg_x[NPARTS], bg_y[NPARTS], bg_z[NPARTS], bg_cr[NPARTS];

static int GridCell(const SimPart *p)
{
    int gx = (int)((p->x + 1.0) / grid_size);
    int gy = (int)((p->y + 1.0) / grid_size);
    if (gx < 0) gx = 0;
    if (gx >= GRID_N) gx = GRID_N - 1;
    if (gy < 0) gy = 0;
    if (gy >= GRID_N) gy = GRID_N - 1;
    return gy * GRID_N + gx;
}
static u16     order[NPARTS];       /* 表に書く順。種類ごとに z 順 (奥から) */
static double  sim_time = 0.0;
static double  sim_tube_vel = 0.9;  /* 参照実装の初期値 */
static double  sim_fluid_vel = 0.0;
/* 筒を手で回す (参照実装の keyTurn。矢印キーを押している間 ±1.2)。
 * シリアルには「離した」が来ないので、キーが届くたびに一定時間だけ効かせる。
 * キーリピートの最初の間 (0.5 秒ほど) で途切れないよう 0.6 秒にした */
static double  sim_key_turn = 0.0;
static double  sim_key_turn_left = 0.0;   /* あと何秒効かせるか */

/* 乱数 (xorshift32)。参照実装の Math.random() の代わり。0 以上 1 未満 */
static u32 rng_state = 0x2545F491u;
static double rnd(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return (rng_state >> 8) * (1.0 / 16777216.0);
}
/* 同じ乱数の単精度版 (移動のループ用) */
static inline float rndf(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return (rng_state >> 8) * (1.0f / 16777216.0f);
}

static void SimInit(void)
{
    grid_size = 2.0 / GRID_N;
    for (int i = 0; i < NPARTS; i++) {
        const Part *p = &parts[i];
        SimPart *s = &sp[i];
        s->x = p->x;  s->y = p->y;  s->z = p->z;
        s->vx = s->vy = s->vz = 0.0;
        s->rot = p->rot;  s->spin = 0.0;
        s->sink = type_sink[p->typ] * (0.75 + 0.5 * rnd());   /* rand(0.75, 1.25) */
        s->cr = p->r * type_cr[p->typ];
        order[i] = (u16)i;
    }
    SimLists();
    xil_printf("押し合いのマス: 一辺 %d/1000、小 %d 個 (マス目)、大 %d 個 (別に調べる)\r\n",
               (int)(grid_size * 1000.0), nsolid, nbig);
}

/* 押し合いに加わるもの (当たり判定があり、今の構成で出しているもの) を小と大に分ける。
 * 構成 (set_comp) を変えたら呼び直す */
static void SimLists(void)
{
    nsolid = nbig = 0;
    small_cr_max = 0.0f;
    for (int i = 0; i < NPARTS; i++) {
        const SimPart *s = &sp[i];
        if (s->cr <= 0.0 || !PART_SHOWN(i)) continue;
        if (2.0 * s->cr <= grid_size) {
            solid[nsolid++] = (u16)i;
            if ((float)s->cr > small_cr_max) small_cr_max = (float)s->cr;
        } else {
            big[nbig++] = (u16)i;
        }
    }
}

/* 押し合いの 1 組。重なっていれば当たり判定の面積 (cr^2) の比で押し離す */
static inline void PushPair(float *xa, float *ya, float za, float cra,
                            float *xb, float *yb, float zb, float crb)
{
    n_pair_sum++;
    if (fabsf(za - zb) > 0.45f) return;
    const float dx = *xb - *xa, dy = *yb - *ya;
    const float minD = cra + crb;
    const float d2 = dx * dx + dy * dy;
    if (d2 >= minD * minD || d2 == 0.0f) return;
    n_hit_sum++;
    const float d = sqrtf(d2);
    const float ov = (minD - d) / d;
    const float ma = cra * cra, mb = crb * crb;
    const float m = ma + mb;
    *xa -= dx * ov * mb / m;  *ya -= dy * ov * mb / m;
    *xb += dx * ov * ma / m;  *yb += dy * ov * ma / m;
}

/* 座標をマスの番号 (1 方向) にする。筒の外は端のマスに入れる */
static inline int GridIdx(float v)
{
    int g = (int)((v + 1.0f) / (float)grid_size);
    return (g < 0) ? 0 : (g >= GRID_N) ? GRID_N - 1 : g;
}

static void StepSim(double dt)
{
    /* 筒: 自動回転の速さ (+ 手で回している分) へ近づける */
    if (sim_key_turn_left > 0.0) {
        sim_key_turn_left -= dt;
        if (sim_key_turn_left <= 0.0) sim_key_turn = 0.0;
    }
    if (set_rev > 0) {
        sim_rev_t += dt;
        if (sim_rev_t >= set_rev) { sim_rev_t -= set_rev; sim_rev_dir = -sim_rev_dir; }
    }
    const double target = set_autorotate * 0.6 * sim_rev_dir + sim_key_turn;
    sim_tube_vel += (target - sim_tube_vel)
                    * (1.0 - exp(-dt * (sim_key_turn != 0.0 ? 4.0 : 1.2)));
    sim_tube_angle += sim_tube_vel * dt;
    if (sim_tube_angle >= TWO_PI_D) sim_tube_angle -= TWO_PI_D;
    if (sim_tube_angle < 0.0)       sim_tube_angle += TWO_PI_D;

    /* 油: 粘りに応じて筒から遅れて追従する */
    const double thin = pow(2.5, (0.5 - set_viscosity) * 2.0);
    sim_fluid_vel += (sim_tube_vel - sim_fluid_vel) * (1.0 - exp(-dt * thin / 2.2));
    const double wRel = sim_fluid_vel - sim_tube_vel;
    const double gx = -sin(sim_tube_angle), gy = -cos(sim_tube_angle);   /* -upInCell */
    const double k = 1.0 - exp(-dt * 6.0 * thin);
    const double t = sim_time;
    XTime ta, tb, tc, td;
    XTime_GetTime(&ta);

    /* 移動は単精度で計算する (2038 個 x 2 回で倍精度だと 1.7ms)。状態 sp[] は倍精度のまま。
     * 時刻の位相は倍精度で 2π に折り返してから渡す (時間がたっても sinf の精度が落ちない) */
    const float fk = (float)k, fdt = (float)dt, fw = (float)wRel;
    const float fgx = (float)gx, fgy = (float)gy, fthin = (float)thin;
    const float ph_x = (float)fmod(t * 0.31, TWO_PI_D), ph_y = (float)fmod(t * 0.27, TWO_PI_D);
    for (int i = 0; i < NPARTS; i++) {
        SimPart *p = &sp[i];
        const int typ = parts[i].typ;
        float x = (float)p->x, y = (float)p->y, vx = (float)p->vx, vy = (float)p->vy;
        /* 筒との回転差による渦 + ゆるい対流 (ラメほど流されやすい) + 沈降 */
        const float drift = (typ == TYPE_GLITTER) ? 0.09f : 0.03f;
        const float sink = (float)p->sink * fthin;
        const float tx = -fw * y + drift * sinf(y * 3.1f + ph_x)
                         + fgx * sink + (rndf() - 0.5f) * 0.02f;
        const float ty =  fw * x + drift * cosf(x * 2.7f - ph_y)
                         + fgy * sink + (rndf() - 0.5f) * 0.02f;
        vx += (tx - vx) * fk;
        vy += (ty - vy) * fk;
        x += vx * fdt;
        y += vy * fdt;
        p->x = x;  p->y = y;  p->vx = vx;  p->vy = vy;
        if (typ != TYPE_BUBBLE) {
            float z = (float)p->z, vz = (float)p->vz;
            vz += ((rndf() - 0.5f) * 0.5f - vz * 1.5f) * fdt;
            z += vz * fdt * 0.15f;
            if (z < 0.02f) { z = 0.02f; vz =  fabsf(vz); }
            if (z > 0.98f) { z = 0.98f; vz = -fabsf(vz); }
            p->z = z;  p->vz = vz;
        }
        const float speed = sqrtf(vx * vx + vy * vy);
        const float cross = vx * fgy - vy * fgx;
        const float sgn = (cross > 0.0f) ? 1.0f : (cross < 0.0f) ? -1.0f : 1.0f;  /* sign(..||1) */
        float spin = (float)p->spin;
        spin += (fw * 0.8f - spin) * fk;
        p->spin = spin;
        p->rot += (spin + speed * 0.3f / (float)parts[i].r * sgn) * fdt;
    }

    /* 押し合い。奥行きが離れていれば重なってよい。
     * 全部の組 (598 個のとき当たり判定のある 318 個で約 5 万組) を調べると 1 フレーム
     * 15.5ms かかったので、筒の中をマス目に分け、同じマスと隣のマスだけを調べる。
     * マスの一辺は「当たる最大の距離」(cr の最大の 2 倍) 以上なので取りこぼさない。
     * 参照実装とは組を処理する順序だけが違う */
    XTime_GetTime(&tb);
    for (int it = 0; it < 2; it++) {
        /* マスごとに数えて、マス目の順に詰める (数え上げソート) */
        static u16 cell_of[NPARTS];
        for (int c = 0; c < GRID_N * GRID_N; c++) cell_fill[c] = 0;
        for (int i = 0; i < nsolid; i++) {
            cell_of[i] = (u16)GridCell(&sp[solid[i]]);
            cell_fill[cell_of[i]]++;
        }
        cell_start[0] = 0;
        for (int c = 0; c < GRID_N * GRID_N; c++) {
            cell_start[c + 1] = cell_start[c] + cell_fill[c];
            cell_fill[c] = cell_start[c];
        }
        for (int i = 0; i < nsolid; i++) {
            const int k = cell_fill[cell_of[i]]++;
            const SimPart *s = &sp[solid[i]];
            pk_idx[k] = solid[i];
            pk_x[k] = (float)s->x;  pk_y[k] = (float)s->y;
            pk_z[k] = (float)s->z;  pk_cr[k] = (float)s->cr;
        }
        for (int j = 0; j < nbig; j++) {
            const SimPart *s = &sp[big[j]];
            bg_x[j] = (float)s->x;  bg_y[j] = (float)s->y;
            bg_z[j] = (float)s->z;  bg_cr[j] = (float)s->cr;
        }
        /* 同じマスの中と、隣のマスのうち片側半分 (右・左下・下・右下) だけを調べる。
         * 反対側の 4 マスは、相手のマスから見たときに調べられる */
        static const int nbr_dx[4] = { 1, -1, 0, 1 };
        static const int nbr_dy[4] = { 0,  1, 1, 1 };
        for (int cy = 0; cy < GRID_N; cy++) {
            for (int cx = 0; cx < GRID_N; cx++) {
                const int c = cy * GRID_N + cx;
                for (int a = cell_start[c]; a < cell_start[c + 1]; a++) {
                    for (int nb = -1; nb < 4; nb++) {
                        int b0, b1;
                        if (nb < 0) {
                            b0 = a + 1;  b1 = cell_start[c + 1];
                        } else {
                            const int nx = cx + nbr_dx[nb], ny = cy + nbr_dy[nb];
                            if (nx < 0 || nx >= GRID_N || ny >= GRID_N) continue;
                            const int n = ny * GRID_N + nx;
                            b0 = cell_start[n];  b1 = cell_start[n + 1];
                        }
                        for (int b = b0; b < b1; b++)
                            PushPair(&pk_x[a], &pk_y[a], pk_z[a], pk_cr[a],
                                     &pk_x[b], &pk_y[b], pk_z[b], pk_cr[b]);
                    }
                }
            }
        }
        /* 大と小。大の中心から「大の cr + 小の cr の最大」までにかかるマスを全部見る
         * (cr 0.042 でも前後 2 マスずつ) */
        for (int j = 0; j < nbig; j++) {
            const float reach = bg_cr[j] + small_cr_max;
            const int gx0 = GridIdx(bg_x[j] - reach), gx1 = GridIdx(bg_x[j] + reach);
            const int gy0 = GridIdx(bg_y[j] - reach), gy1 = GridIdx(bg_y[j] + reach);
            for (int gy = gy0; gy <= gy1; gy++)
                for (int gx = gx0; gx <= gx1; gx++) {
                    const int c = gy * GRID_N + gx;
                    for (int b = cell_start[c]; b < cell_start[c + 1]; b++)
                        PushPair(&bg_x[j], &bg_y[j], bg_z[j], bg_cr[j],
                                 &pk_x[b], &pk_y[b], pk_z[b], pk_cr[b]);
                }
        }
        /* 大どうしは全部の組 (50 個で約 1200 組) */
        for (int j = 0; j < nbig; j++)
            for (int j2 = j + 1; j2 < nbig; j2++)
                PushPair(&bg_x[j], &bg_y[j], bg_z[j], bg_cr[j],
                         &bg_x[j2], &bg_y[j2], bg_z[j2], bg_cr[j2]);
        /* 押し合いで動いた位置を戻す */
        for (int k = 0; k < nsolid; k++) {
            SimPart *s = &sp[pk_idx[k]];
            s->x = pk_x[k];  s->y = pk_y[k];
        }
        for (int j = 0; j < nbig; j++) {
            SimPart *s = &sp[big[j]];
            s->x = bg_x[j];  s->y = bg_y[j];
        }
    }
    /* 筒の内壁 */
    XTime_GetTime(&tc);
    for (int i = 0; i < NPARTS; i++) {
        SimPart *p = &sp[i];
        const double d = sqrt(p->x * p->x + p->y * p->y);
        const double half_r = parts[i].r * 0.5;
        const double lim = 0.985 - (p->cr > half_r ? p->cr : half_r);
        if (d > lim) { p->x *= lim / d;  p->y *= lim / d; }
    }
    XTime_GetTime(&td);
    t_move_sum += tb - ta;
    t_push_sum += tc - tb;
    t_wall_sum += td - tc;
    sim_time += dt;
}

/* かき混ぜる (参照実装の「振る」ボタン)。油を左右どちらかへ一気に回し、
 * ピースの速さもばらつかせる */
static void SimStir(void)
{
    sim_fluid_vel += (rnd() < 0.5 ? -1.0 : 1.0) * 7.0;
    for (int i = 0; i < NPARTS; i++) {
        sp[i].vx += rnd() * 1.2 - 0.6;     /* rand(-0.6, 0.6) */
        sp[i].vy += rnd() * 1.2 - 0.6;
    }
}

/* 筒を手で回す。dir = +1 で j (左)、-1 で l (右) */
static void SimTurn(double dir)
{
    sim_key_turn = 1.2 * dir;
    sim_key_turn_left = 0.6;
}

/* 表を書く。物理演算の位置・奥行き・回転で 24 語を作る。
 * 並びは種類ごとにまとめたまま (枠に詰めるため)、種類の中は z 順 (奥から) に
 * 並べ直す。z が動くので毎回並べ直す (ほぼ整列済みなので挿入ソートで速い)。
 * ★ rot は 0〜2π に収めること。ラメのプログラムは rot*4 + seed*60 の
 *   折り返しが S6.17 (±64) にぎりぎり収まる前提 (CLAUDE.md「ハマったところ」) */
/* ピース n の色を今の組み合わせ (palettes[]) で決める。0 番 (生成したときの色) なら何もしない */
static void ApplyPalette(Part *p, int n)
{
    if (p->kind == KIND_BUBBLE) return;
    const KindColor *kc = &cset[p->kind];
    u32 sum = 0;
    for (int j = 0; j < KCOLS; j++) sum += kc->rate[j];
    if (sum == 0) return;                            /* 全部 0 なら元の色のまま */
    const u32 h = (u32)n * 2654435761u;              /* 番号を混ぜて偏りを無くす */
    u32 pick = (h >> 16) % sum;                      /* 割合に比例して色を選ぶ */
    int j = 0;
    while (pick >= kc->rate[j]) { pick -= kc->rate[j]; j++; }
    const u8 *c = kc->rgb[j];
    /* 配色エディタを開いている間は、直している種類のピースを全部点滅させる。
     * 1 色だけ直しても目立たず「色が変わらない」と言われたため (2026-10-22)。
     * 最初は直している色のピースだけ点滅させたが、ガラスでも約 20 個しかなく
     * 「どこか分からない」と言われたので種類ごとにした。
     * 0.6 秒周期で、半分は元の色、半分は白か黒 (元の色が明るければ黒) */
    if (ed_on && p->kind == ed_kind && fmod(sim_time, 0.6) < 0.3) {
        const u8 v = (c[0] + c[1] + c[2] > 384) ? 0 : 255;
        p->col[0] = p->col[1] = p->col[2] = v;
        return;
    }
    double fr = p->seed * 7.3;
    fr -= floor(fr);
    const double jit = 0.88 + 0.20 * fr;
    for (int k = 0; k < 3; k++) {
        const double v = c[k] * jit;
        p->col[k] = (v > 255.0) ? 255 : (u8)v;
    }
}

/* 組み込みの組 n を今の配色 cset[] へ写す。ORIGINAL は kind_orig[] (生成したときの色)。
 * それ以外は palettes[] の 3 つの並びを種類に割り振り、割合は等分する。
 * きらめき層の点 (SPARK) は、ORIGINAL なら段7 の白・金・淡い青 (2:1:1)、それ以外はラメの並び */
static void LoadPreset(int n)
{
    for (int k = 0; k < NKINDS; k++)
        for (int j = 0; j < KCOLS; j++) {
            for (int i = 0; i < 3; i++) cset[k].rgb[j][i] = kind_orig[k][j][i];
            cset[k].rate[j] = kind_orig[k][j][3];
        }
    static const u8 spk_orig[3][4] = { {255, 255, 255, 50}, {255, 224, 140, 25}, {191, 217, 255, 25} };
    KindColor *sk = &cset[KIND_SPARK];
    for (int j = 0; j < KCOLS; j++) {
        for (int i = 0; i < 3; i++) sk->rgb[j][i] = (j < 3) ? spk_orig[j][i] : 0;
        sk->rate[j] = (j < 3) ? spk_orig[j][3] : 0;
    }
    if (n > 0) {
        for (int j = 0; j < KCOLS; j++) {
            for (int i = 0; i < 3; i++) sk->rgb[j][i] = palettes[n].glit[j % 4][i];
            sk->rate[j] = (j < 4) ? 25 : 0;
        }
    }
    if (n > 0) {
        const Palette *pl = &palettes[n];
        for (int k = 0; k < NKIND_EDIT; k++) {
            const int nc = (k == KIND_GLITTER) ? 4 : (k == KIND_BEAD || k == KIND_SBEAD) ? 4 : 6;
            for (int j = 0; j < KCOLS; j++) {
                const u8 *c = (k == KIND_GLITTER) ? pl->glit[j % 4]
                            : (k == KIND_BEAD || k == KIND_SBEAD) ? pl->bead[j % 4]
                            : pl->solid[j % 6];
                for (int i = 0; i < 3; i++) cset[k].rgb[j][i] = c[i];
                cset[k].rate[j] = (j < nc) ? (u8)(100 / nc) : 0;
            }
        }
    }
    set_palette = n;
    int i = 0;
    for (const char *s = palettes[n].name; *s && i < (int)sizeof(cset_name) - 1; s++) cset_name[i++] = *s;
    cset_name[i] = '\0';
}

/* ========== 配色を SD カードに保存・読み込み ==========
 * SD カードの FAT の区画の一番上に KPAL1.TXT 〜 KPAL4.TXT を置く (他のファイルと同居できる)。
 * BSP に xilffs (FatFs) が要る。ファイル名は 8.3 形式だけ (長い名前は BSP で無効)。
 * 中身は人が読める文字で、PC で直してもよい:
 *     # KV260 kaleidoscope colors (JEWEL)
 *     BEAD FFFFFF/25 FFD778/25 FF96AA/25 96DCFF/25 000000/0 000000/0 000000/0 000000/0
 *     S.BEAD ...
 *     SPARK ...                  (きらめき層の点。段7b)
 *     SPKPARAM 45 100 75         (きらめき層の量 [%]・明るさ [%]・大きさ [画素 x100])
 *     SETTING 6 3 130 50 10 30   (ポイント・ミラー・大きさ・回転・往復 [秒]・粘り。無ければ変えない)
 * 1 行 = 種類の名前 + 「色 (RRGGBB の 16 進)/割合 [%]」が 8 つ。書いていない種類は今の色のまま。
 * SD を挿し替えても追従するように、保存・読み込みのたびにつなぎ直す。
 * 書き込み・読み込みは数 ms〜数十 ms かかるので、その間は映像の歩調から外れる (キーを押したときだけ) */
static FATFS sd_fs;
static FIL   sd_fil;
static char  sd_buf[2048] __attribute__((aligned(64)));    /* SD の DMA に合わせて揃える */

static int SdMount(void)
{
    f_mount(NULL, "0:/", 0);
    return (f_mount(&sd_fs, "0:/", 1) == FR_OK) ? 0 : -1;
}

static void SdPath(char *path, int slot)
{
    snprintf(path, 16, "0:/KPAL%d.TXT", slot);
}

/* 戻り値: 0 = 保存した, -1 = SD が無い/読めない, -2 = 開けない, -3 = 書けない */
static int SdSave(int slot)
{
    char path[16];
    if (SdMount() != 0) return -1;
    SdPath(path, slot);
    int n = snprintf(sd_buf, sizeof(sd_buf),
                     "# KV260 kaleidoscope colors (%s)\r\n# kind  RRGGBB/rate[%%] x %d\r\n",
                     cset_name, KCOLS);
    for (int k = 0; k < NCSET; k++) {
        if (!KIND_EDITABLE(k)) continue;
        n += snprintf(sd_buf + n, sizeof(sd_buf) - n, "%s", kind_name[k]);
        for (int j = 0; j < KCOLS; j++)
            n += snprintf(sd_buf + n, sizeof(sd_buf) - n, " %02X%02X%02X/%u",
                          cset[k].rgb[j][0], cset[k].rgb[j][1], cset[k].rgb[j][2],
                          (unsigned)cset[k].rate[j]);
        n += snprintf(sd_buf + n, sizeof(sd_buf) - n, "\r\n");
    }
    /* きらめき層の量 [%]・明るさ [%]・大きさ [画素 x100] */
    n += snprintf(sd_buf + n, sizeof(sd_buf) - n, "SPKPARAM %d %d %d\r\n",
                  spk_amount, spk_bright, spk_size);
    /* 模様の設定 (画面の一覧と同じ数): ポイント・ミラー・大きさ・回転・往復 [秒]・粘り */
    n += snprintf(sd_buf + n, sizeof(sd_buf) - n, "SETTING %d %d %d %d %d %d\r\n",
                  set_points, set_mirror2 ? 2 : 3, (int)(set_zoom * 100.0f + 0.5f),
                  (int)(set_autorotate * 100.0f + 0.5f), set_rev,
                  (int)(set_viscosity * 100.0f + 0.5f));
    if (f_open(&sd_fil, path, FA_CREATE_ALWAYS | FA_WRITE) != FR_OK) return -2;
    UINT bw = 0;
    FRESULT r = f_write(&sd_fil, sd_buf, (UINT)n, &bw);
    f_close(&sd_fil);
    return (r == FR_OK && bw == (UINT)n) ? 0 : -3;
}

/* 「RRGGBB/割合」を 1 つ読む。読めなければ NULL */
static const char *ParseEntry(const char *p, u8 rgb[3], u8 *rate)
{
    while (*p == ' ' || *p == '\t') p++;
    u32 v = 0;
    for (int i = 0; i < 6; i++, p++) {
        const char ch = *p;
        int d = (ch >= '0' && ch <= '9') ? ch - '0'
              : (ch >= 'A' && ch <= 'F') ? ch - 'A' + 10
              : (ch >= 'a' && ch <= 'f') ? ch - 'a' + 10 : -1;
        if (d < 0) return NULL;
        v = (v << 4) | (u32)d;
    }
    if (*p++ != '/') return NULL;
    u32 w = 0;
    if (*p < '0' || *p > '9') return NULL;
    while (*p >= '0' && *p <= '9') w = w * 10 + (u32)(*p++ - '0');
    rgb[0] = (u8)(v >> 16);  rgb[1] = (u8)(v >> 8);  rgb[2] = (u8)v;
    *rate = (u8)((w > 100) ? 100 : w);
    return p;
}

/* 空白区切りの 10 進数を n 個まで読む。戻り値は読めた数 */
static int ParseInts(const char *p, int *v, int n)
{
    int i = 0;
    while (i < n) {
        while (*p == ' ' || *p == '\t') p++;
        if (*p < '0' || *p > '9') break;
        v[i] = 0;
        while (*p >= '0' && *p <= '9') v[i] = v[i] * 10 + (*p++ - '0');
        i++;
    }
    return i;
}

static int ClampI(int v, int lo, int hi) { return (v < lo) ? lo : (v > hi) ? hi : v; }

/* 戻り値: 読めた種類の数 (1 以上), -1 = SD が無い/読めない, -2 = ファイルが無い,
 *         -3 = 読めない, -4 = 中身に種類の行が無い */
static int SdLoad(int slot)
{
    char path[16];
    if (SdMount() != 0) return -1;
    SdPath(path, slot);
    if (f_open(&sd_fil, path, FA_READ) != FR_OK) return -2;
    UINT br = 0;
    FRESULT r = f_read(&sd_fil, sd_buf, sizeof(sd_buf) - 1, &br);
    f_close(&sd_fil);
    if (r != FR_OK) return -3;
    sd_buf[br] = '\0';

    static KindColor tmp[NCSET];           /* 途中で壊れた行があっても今の配色を壊さない */
    memcpy(tmp, cset, sizeof(cset));
    int got = 0;
    char *s = sd_buf;
    while (*s) {
        char *e = s;
        while (*e && *e != '\n') e++;
        const char save = *e;
        *e = '\0';
        int v[6];
        if (strncmp(s, "SPKPARAM ", 9) == 0 && ParseInts(s + 9, v, 3) == 3) {   /* きらめき層 */
            spk_amount = ClampI(v[0], 0, 100);
            spk_bright = ClampI(v[1], 0, 200);
            spk_size   = ClampI(v[2], 50, 200);
        }
        /* 模様の設定。この行が無い古いファイルは設定を変えない。鏡の法線などは呼び手が
         * KalSetGeometry で書き直す。値はキーで動く刻みに丸める (5 / 10 刻みからずれないように) */
        if (strncmp(s, "SETTING ", 8) == 0 && ParseInts(s + 8, v, 6) == 6) {
            set_points     = ClampI(v[0], 3, 12);
            set_mirror2    = (v[1] == 2);
            set_zoom       = ClampI((v[2] + 2) / 5 * 5, (int)(ZOOM_MIN * 100.0f + 0.5f),
                                    (int)(ZOOM_MAX * 100.0f + 0.5f)) / 100.0f;
            set_autorotate = ClampI((v[3] + 2) / 5 * 5, 0, 100) / 100.0f;
            set_rev        = (v[4] == 5 || v[4] == 10 || v[4] == 20) ? v[4] : 0;
            set_viscosity  = ClampI((v[5] + 5) / 10 * 10, 0, 100) / 100.0f;
            sim_rev_t = 0.0;  sim_rev_dir = 1.0;
        }
        for (int k = 0; k < NCSET && *s != '#'; k++) {
            if (!KIND_EDITABLE(k)) continue;
            const size_t len = strlen(kind_name[k]);
            if (strncmp(s, kind_name[k], len) != 0 || (s[len] != ' ' && s[len] != '\t')) continue;
            const char *p = s + len;
            KindColor kc;
            int j;
            for (j = 0; j < KCOLS && p; j++) p = ParseEntry(p, kc.rgb[j], &kc.rate[j]);
            if (p) { tmp[k] = kc; got++; }
            break;
        }
        *e = save;
        s = (*e) ? e + 1 : e;
    }
    if (got == 0) return -4;
    memcpy(cset, tmp, sizeof(cset));
    snprintf(cset_name, sizeof(cset_name), "SLOT%d", slot);
    return got;
}

/* おまかせモードの切り替え。次の KPAL を読み、配色と設定 (SETTING 行) を変える。
 * 読めないファイル (無い・壊れている) は飛ばす。4 つとも読めなければ何もしない */
static void AutoNext(void)
{
    /* 大きさだけは今のまま (KPAL ごとに 80〜180 と違い、切り替わるたびに大きさが跳ぶと言われた) */
    const float zoom = set_zoom;
    for (int k = 0; k < 4; k++) {
        auto_slot = auto_slot % 4 + 1;
        if (SdLoad(auto_slot) > 0) {
            set_zoom = zoom;
            /* 色の組と構成も、今と違うものを乱数で選ぶ (KPAL の 4 つだけでは「あまり変わらない」と
             * 言われた)。KPAL から使うのは設定 (SETTING 行) だけになる */
            LoadPreset((set_palette + 1 + (int)(rnd() * (NPALETTES - 1))) % NPALETTES);
            set_comp = (set_comp + 1 + (int)(rnd() * (NCOMPS - 1))) % NCOMPS;
            SimLists();
            KalSetGeometry();              /* ポイント・ミラー・大きさ・きらめき層を書き直す */
            UpdateText();
            xil_printf("おまかせ: KPAL%d.TXT\r\n", auto_slot);
            ShowSettings();
            return;
        }
    }
    xil_printf("おまかせ: SD の KPAL1〜4 が読めない\r\n");
}

/* ========== 配色エディタ (p キーで出す/閉じる) ==========
 * 画面の操作一覧の代わりに出る。今の配色 cset[] を直接直すので、模様を見ながら決められる
 * (次の描き直しから変わる)。色見本は出さない (画面の文字は白だけ)。
 * 種類 → 色の番号 (1〜8) を選び、赤・緑・青と割合を増減する。
 * エディタの中ではキーの意味が変わる (下の EditKey)。 */
#define ED_RGB_STEP   8
#define ED_RATE_STEP  5

static void SdMessage(const char *what, int slot, int r)
{
    if (r >= 0) {
        snprintf(ed_msg, sizeof(ed_msg), "%s %d", what, slot);
        xil_printf("SD: %s KPAL%d.TXT\r\n", (what[0] == 'S') ? "保存した" : "読み込んだ", slot);
        return;
    }
    const char *m = (r == -1) ? "NO SD" : (r == -2) ? "NO FILE" : (r == -4) ? "BAD FILE" : "SD ERROR";
    snprintf(ed_msg, sizeof(ed_msg), "%s", m);
    xil_printf("SD: KPAL%d.TXT  %s (%d)\r\n", slot, m, r);
}

static void ShowEdit(void)
{
    const KindColor *kc = &cset[ed_kind];
    u32 sum = 0;
    for (int j = 0; j < KCOLS; j++) sum += kc->rate[j];
    xil_printf("配色 %s  %s  色 %d/%d  R %3d G %3d B %3d  割合 %3d (この種類の合計 %u)\r\n",
               cset_name, kind_name[ed_kind], ed_col + 1, KCOLS,
               kc->rgb[ed_col][0], kc->rgb[ed_col][1], kc->rgb[ed_col][2],
               kc->rate[ed_col], (unsigned)sum);
    if (ed_kind == KIND_SPARK)
        xil_printf("  きらめき層  量 %d%%  明るさ %d%%  大きさ %d (半径 x100 画素)\r\n",
                   spk_amount, spk_bright, spk_size);
}

static void ShowEditHelp(void)
{
    /* ShowHelp と同じくキーボードの並びで出す */
    xil_printf("\r\n\r\n\r\n--- 配色エディタのキー (キーボードの並び。p で閉じる。/ でこの一覧) ---\r\n");
    xil_printf(" [1]保存1 [2]保存2 [3]保存3 [4]保存4 [5]読込1 [6]読込2 [7]読込3 [8]読込4\r\n");
    xil_printf("  [q]種類< [w]種類> [e]赤+ [r]緑+ [t]青+ [y]割合+ [u]量+ [i]明+ [o]大+ [p]閉じる\r\n");
    xil_printf("   [a]色< [s]色> [d]赤- [f]緑- [g]青- [h]割合- [j]量- [k]明- [l]大-\r\n");
    xil_printf("                      [c]組を写す\r\n");
    xil_printf("  種類: BEAD S.BEAD GLASS GLITTER STONE HEX ROD BLOB MOON SPARK (選んだ種類が点滅)\r\n");
    xil_printf("  色< > は色の番号 1〜%d。赤緑青は %d ずつ。割合は %d%% ずつ (0 の色は使わない)\r\n",
               KCOLS, ED_RGB_STEP, ED_RATE_STEP);
    xil_printf("  量 明(明るさ) 大(大きさ) は SPARK のときだけ。c は組み込みの組を写す (直しは消える)\r\n");
    xil_printf("  保存・読込は SD の KPAL1〜4.TXT\r\n");
    xil_printf("  / はモニターの文字もキーの並びの絵にする (もう一度 / で戻る)。絵の略語:\r\n");
    xil_printf("    S1〜4保存 L1〜4読込 K種類 C色の番号 RGB色 %%割合 N量 L明るさ Z大きさ EX閉じる CP組を写す\r\n");
    ShowEdit();
}

static int Clamp255(int v) { return (v < 0) ? 0 : (v > 255) ? 255 : v; }

/* 直せる種類を dir (+1/-1) 方向に 1 つ進める。気泡は飛ばす */
static int NextKind(int k, int dir)
{
    do { k = (k + dir + NCSET) % NCSET; } while (!KIND_EDITABLE(k));
    return k;
}

static void EditKey(int c)
{
    KindColor *kc = &cset[ed_kind];
    u8 *rgb = kc->rgb[ed_col];
    const int spk = (ed_kind == KIND_SPARK);
    ed_msg[0] = '\0';
    switch (c) {
    case 'q': ed_kind = NextKind(ed_kind, -1); break;
    case 'w': ed_kind = NextKind(ed_kind, +1); break;
    /* きらめき層の量・明るさ・大きさ (SPARK を選んでいるときだけ) */
    case 'u': if (spk && spk_amount < 100) spk_amount += 5;  break;
    case 'j': if (spk && spk_amount > 0)   spk_amount -= 5;  break;
    case 'i': if (spk && spk_bright < 200) spk_bright += 10; break;
    case 'k': if (spk && spk_bright > 0)   spk_bright -= 10; break;
    case 'o': if (spk && spk_size < 200)   spk_size   += 25; break;
    case 'l': if (spk && spk_size > 50)    spk_size   -= 25; break;
    case 'a': ed_col  = (ed_col + KCOLS - 1) % KCOLS;            break;
    case 's': ed_col  = (ed_col + 1) % KCOLS;                    break;
    case 'e': rgb[0] = (u8)Clamp255(rgb[0] + ED_RGB_STEP); break;
    case 'd': rgb[0] = (u8)Clamp255(rgb[0] - ED_RGB_STEP); break;
    case 'r': rgb[1] = (u8)Clamp255(rgb[1] + ED_RGB_STEP); break;
    case 'f': rgb[1] = (u8)Clamp255(rgb[1] - ED_RGB_STEP); break;
    case 't': rgb[2] = (u8)Clamp255(rgb[2] + ED_RGB_STEP); break;
    case 'g': rgb[2] = (u8)Clamp255(rgb[2] - ED_RGB_STEP); break;
    case 'y': kc->rate[ed_col] = (u8)((kc->rate[ed_col] + ED_RATE_STEP > 100) ? 100
                                      : kc->rate[ed_col] + ED_RATE_STEP); break;
    case 'h': kc->rate[ed_col] = (u8)((kc->rate[ed_col] < ED_RATE_STEP) ? 0
                                      : kc->rate[ed_col] - ED_RATE_STEP); break;
    case 'c': LoadPreset((set_palette + 1) % NPALETTES); break;
    case '1': case '2': case '3': case '4':
        SdMessage("SAVED", c - '0', SdSave(c - '0'));
        break;
    case '5': case '6': case '7': case '8':
        SdMessage("LOADED", c - '4', SdLoad(c - '4'));
        KalSetGeometry();                  /* SETTING の行でポイント・ミラー・大きさが変わる */
        auto_slot = c - '4';               /* おまかせはこの次の番号から */
        break;
    case 'p': ed_on = 0; txt_keys = 0; UpdateText(); ShowHelp(); return;
    /* h は割合 - に使うので一覧は / と ? (/ は Shift 不要)。モニターもキーの並びの絵と切り替える */
    case '/': case '?': txt_keys = !txt_keys; UpdateText(); ShowEditHelp(); return;
    default: xil_printf("(割り当て無し)\r\n"); return;
    }
    SpkSet();                              /* きらめき層の色・量・明るさ・大きさ (COMMIT は下の UpdateText) */
    UpdateText();
    ShowEdit();
}

static void WriteTable(void)
{
    /* parts[] は種類ごとに連続している。種類の切れ目ごとに z で挿入ソート */
    int g0 = 0;
    for (int i = 1; i <= NPARTS; i++) {
        if (i < NPARTS && parts[order[i]].typ == parts[order[g0]].typ) continue;
        for (int a = g0 + 1; a < i; a++) {
            u16 v = order[a];
            int b = a - 1;
            while (b >= g0 && sp[order[b]].z > sp[v].z) { order[b + 1] = order[b]; b--; }
            order[b + 1] = v;
        }
        g0 = i;
    }

    u32 w[PIECE_WORDS];
    glit_time = fmod(sim_time * GLIT_SPEED, GLIT_WRAP);
    Xil_Out32(KAL_CELL_CTRL, CELL_SEL_TABLE);      /* 表の番地を 0 に戻す */
    for (int i = 0; i < NPARTS; i++) {
        const int n = order[i];
        if (!PART_SHOWN(n)) continue;              /* 今の構成で出さない種類 */
        const SimPart *s = &sp[n];
        Part p = parts[n];                         /* 種類・色・大きさ・種はそのまま */
        p.x = s->x;  p.y = s->y;  p.z = s->z;
        ApplyPalette(&p, n);                       /* 色の組み合わせ (c キー) */
        double rot = fmod(s->rot, TWO_PI_D);
        if (rot < 0.0) rot += TWO_PI_D;
        PieceWords(&p, rot, w);
        /* 段6 では 1 語ごとに PL のレジスタを 1 回読んで間隔を空けていた (映像クロックへの
         * 乗り換えが速い書き込みを取りこぼし、描き直しが止まったため)。段6b で表の RAM の
         * 書き込み口を AXI クロックにして乗り換えを無くしたので、続けて書いてよい */
        for (int k = 0; k < PIECE_WORDS; k++)
            Xil_Out32(KAL_CELL_DATA, w[k]);
    }
}

/* ========== 操作一覧をモニターに出す ==========
 * PL の中に 32桁 x 8行 の文字の置き場 (BRAM) がある。ここへ ASCII を
 * 流し込むと、万華鏡の映像の上に白文字で重なって出る。字形は font_rom.hex
 * (8x16 ドットを 2 倍に引き伸ばして描く)。
 * 出せるのは ASCII 0x20〜0x7E だけ。日本語は字形を持っていないので出ない。
 */
static char txt[TXT_ROWS][TXT_COLS];

static void TxtPut(int row, int col, const char *s)
{
    while (*s && col < TXT_COLS) txt[row][col++] = *s++;
}

/* 右詰めで数を置く。col は数の右端 (その桁も使う) */
static void TxtNum(int row, int col, int v)
{
    if (v <= 0) { txt[row][col] = '0'; return; }
    while (v > 0 && col >= 0) { txt[row][col--] = (char)('0' + v % 10); v /= 10; }
}

/* 配色エディタの画面 (32 桁 x 8 行)。p キーで操作一覧と入れ替わる */
static void EditText(void)
{
    const KindColor *kc = &cset[ed_kind];
    TxtPut(0, 0, "COLOR EDIT");
    TxtPut(0, 11, cset_name);
    TxtPut(0, 22, ed_msg);
    TxtPut(1, 0, ">");
    TxtPut(1, 2, kind_name[ed_kind]);
    TxtPut(1, 11, "COLOR");  TxtNum(1, 17, ed_col + 1);  TxtPut(1, 18, "/8");
    TxtPut(1, 22, "RATE");   TxtNum(1, 29, kc->rate[ed_col]);
    static const char *const ch[3] = { "R", "G", "B" };
    for (int i = 0; i < 3; i++) {
        const int v = kc->rgb[ed_col][i];
        TxtPut(2 + i, 2, ch[i]);
        TxtNum(2 + i, 6, v);
        for (int b = 0; b < (v + 8) / 16; b++) txt[2 + i][8 + b] = '#';    /* 0〜16 文字の棒 */
    }
    /* 8 色の割合を並べ、今の色に > を付ける */
    TxtPut(5, 0, "%");
    for (int j = 0; j < KCOLS; j++) {
        TxtNum(5, 4 + j * 3, kc->rate[j]);
        if (j == ed_col) txt[5][2 + j * 3] = '>';
    }
    TxtPut(6, 0, "QW KIND AS COL ED RF TG:RGB +-");
    if (ed_kind == KIND_SPARK) {
        /* きらめき層は量・明るさ・大きさも出す (キーの一覧は ? でシリアルに) */
        TxtPut(7, 0, "UJ AMT");   TxtNum(7, 9, spk_amount);
        TxtPut(7, 11, "IK BRT");  TxtNum(7, 20, spk_bright);
        TxtPut(7, 22, "OL SZ");   TxtNum(7, 30, spk_size);
    } else {
        TxtPut(7, 0, "YH RATE C SET 1-4SV 5-8LD P END");
    }
}

/* キーボードの 1 段ぶんを 2 行に描く。row にキーの文字、row+1 に働き (2 文字)。
 * 1 キー 3 桁で並べ、段ごとに off 桁ずらして本物のキーボードの斜めの並びに似せる。
 * lab[i] が NULL のキーは働きが無いので描かない */
static void KeyRow(int row, int off, const char *keys, const char *const *lab)
{
    for (int i = 0; keys[i]; i++) {
        if (!lab[i]) continue;
        txt[row][off + 3 * i] = keys[i];
        TxtPut(row + 1, off + 3 * i, lab[i]);
    }
}

/* キーボードの並びの絵 (32 桁 x 8 行)。h (エディタでは /) で操作一覧と入れ替わる。
 * 2 文字の略語の意味はシリアルの一覧 (日本語) に出る */
static void KeyText(void)
{
    static const char *const n_num[10] = { 0,0,0,0,0,0,0,0,0, "RS" };
    static const char *const n_q[10]   = { "P-","P+","MX","RV","CM",0,0,"TX","AU","ED" };
    static const char *const n_a[9]    = { "Z-","Z+",0,0,0,"KY","<<",0,">>" };
    static const char *const n_z[7]    = { "S-","S+","CL","V-","V+",0,"MR" };
    static const char *const e_num[10] = { "S1","S2","S3","S4","L1","L2","L3","L4",0,0 };
    static const char *const e_q[10]   = { "K<","K>","R+","G+","B+","%+","N+","L+","Z+","EX" };
    static const char *const e_a[9]    = { "C<","C>","R-","G-","B-","%-","N-","L-","Z-" };
    static const char *const e_z[7]    = { 0,0,"CP",0,0,0,0 };
    const int e = ed_on;
    KeyRow(0, 0, "1234567890", e ? e_num : n_num);
    KeyRow(2, 1, "QWERTYUIOP", e ? e_q   : n_q);
    KeyRow(4, 2, "ASDFGHJKL",  e ? e_a   : n_a);
    KeyRow(6, 3, "ZXCVBNM",    e ? e_z   : n_z);
}

static void UpdateText(void)
{
    int r, c, i;

    for (r = 0; r < TXT_ROWS; r++)
        for (c = 0; c < TXT_COLS; c++) txt[r][c] = ' ';

    if (txt_keys) {
        KeyText();
        goto put;
    }
    if (ed_on) {
        EditText();
        goto put;
    }
    TxtPut(0, 6, "OIL KALEIDOSCOPE");
    if (set_auto > 0) { TxtPut(0, 24, "AUTO");  TxtNum(0, 31, set_auto); }   /* おまかせの間隔 [秒] */
    /* 8 行しか無いので、段6 で増えたキーは 6・7 行目に 2 つずつ詰める */
    TxtPut(1, 2, "Q W   POINTS");  TxtNum(1, 24, set_points);
    TxtPut(2, 2, "M     MIRROR");  TxtNum(2, 24, set_mirror2 ? 2 : 3);
    TxtPut(3, 2, "A S   ZOOM");    TxtNum(3, 24, (int)(set_zoom * 100.0f + 0.5f));
    /* 回転の速さと往復モード (R REV の数字は反転の間隔 [秒]、切なら OFF) */
    TxtPut(4, 2, "Z X SPIN");      TxtNum(4, 14, (int)(set_autorotate * 100.0f + 0.5f));
    TxtPut(4, 17, "R REV");
    if (set_rev > 0) TxtNum(4, 24, set_rev); else TxtPut(4, 22, "OFF");
    TxtPut(5, 2, "V B   THICK");   TxtNum(5, 24, (int)(set_viscosity * 100.0f + 0.5f));
    TxtPut(6, 2, "E STIR  J L TURN  P EDIT");
    TxtPut(6, 27, "T");  TxtPut(6, 29, comps[set_comp].name);   /* 構成 */
    TxtPut(7, 2, "0 RESET I HIDE C");
    TxtPut(7, 19, cset_name);

put:
    /* 4 文字ずつ 1 ワードにまとめて書く。下位バイトが左端の文字。
       txt は 2 次元配列なので行が隙間なく並んでいる。 */
    for (i = 0; i < TXT_COLS * TXT_ROWS / 4; i++) {
        const char *p = &txt[0][0] + i * 4;
        Xil_Out32(KAL_TEXT(i), ((u32)(u8)p[0])       |
                               ((u32)(u8)p[1] << 8)  |
                               ((u32)(u8)p[2] << 16) |
                               ((u32)(u8)p[3] << 24));
    }

    Xil_Out32(KAL_CTRL,   (set_mirror2 ? 1 : 0) | (set_text_on ? 2 : 0));
    Xil_Out32(KAL_COMMIT, 1);
}

/* ========== 鏡の三角形を計算して PL へ渡す ==========
 * 参照実装 mirrorGeometry() と同じ。頂角 180/points の二等辺三角形で、
 * 外接円の半径は MIRROR_R。頂点が上、底辺が下。
 * PL は三角関数を持たない。ここで計算した法線と頂点だけを渡す。
 */
static void KalSetGeometry(void)
{
    const float al = 3.14159265f / (float)set_points;
    const float R  = MIRROR_R;

    float vx[3], vy[3];
    vx[0] = 0.0f;                                 vy[0] = R;
    vx[1] = R * cosf(1.5f * 3.14159265f - al);    vy[1] = R * sinf(1.5f * 3.14159265f - al);
    vx[2] = R * cosf(1.5f * 3.14159265f + al);    vy[2] = R * sinf(1.5f * 3.14159265f + al);

    const float cx = (vx[0] + vx[1] + vx[2]) / 3.0f;
    const float cy = (vy[0] + vy[1] + vy[2]) / 3.0f;

    /* 壁の並びは参照実装と同じ: (A,B) (A,C) (B,C)。[2] が底辺 */
    const int pa[3] = {0, 0, 1};
    const int pb[3] = {1, 2, 2};

    for (int w = 0; w < 3; w++) {
        float ex = vx[pb[w]] - vx[pa[w]];
        float ey = vy[pb[w]] - vy[pa[w]];
        float l  = sqrtf(ex*ex + ey*ey);
        ex /= l; ey /= l;
        float nx =  ey, ny = -ex;
        /* 法線を外向きに揃える (重心と逆を向かせる) */
        if ((cx - vx[pa[w]]) * nx + (cy - vy[pa[w]]) * ny > 0.0f) { nx = -nx; ny = -ny; }
        float d = vx[pa[w]] * nx + vy[pa[w]] * ny;

        Xil_Out32(KAL_WALL(w,0), (u32)(s32)(nx * 65536.0f));   /* Q16 */
        Xil_Out32(KAL_WALL(w,1), (u32)(s32)(ny * 65536.0f));   /* Q16 */
        Xil_Out32(KAL_WALL(w,2), (u32)(s32)(d  * 16384.0f));   /* Q14 */
    }

    for (int v = 0; v < 3; v++) {
        Xil_Out32(KAL_VERT(v,0), (u32)(s32)(vx[v] * 32768.0f));  /* Q15 */
        Xil_Out32(KAL_VERT(v,1), (u32)(s32)(vy[v] * 32768.0f));  /* Q15 */
    }

    /* 画角。kx = 2^27 / (2 * 画面の高さ * focal),  focal = 0.85 * zoom */
    Xil_Out32(KAL_KX,       (u32)(KX_NUM / (1440.0f * 0.85f * set_zoom)));
    Xil_Out32(KAL_Z_MIRROR, (u32)(Z_MIRROR * 65536.0f));                 /* Q16 */
    Xil_Out32(KAL_REMAIN0,  (u32)((Z_CELL - Z_MIRROR) * 16384.0f));      /* Q14 */
    Xil_Out32(KAL_INV_TR,   (u32)(65536.0f / TUBE_R));                   /* Q16 */
    Xil_Out32(KAL_CTRL,     (set_mirror2 ? 1 : 0) | (set_text_on ? 2 : 0));
    Xil_Out32(KAL_COS_T,    32768);
    Xil_Out32(KAL_SIN_T,    0);
    SpkSet();
    Xil_Out32(KAL_COMMIT,   1);
}

/* ========== きらめき層の設定 ==========
 * tools/sparkle_fx.py の params_for_zoom() と同じ式。模様の大きさ (zoom) が変わると
 * 画面 1 画素ぶんの c が変わるので、格子の細かさ lv と点の大きさ k を取り直す。
 * 量・明るさ・大きさ (spk_amount / spk_bright / spk_size) と色の表もここで書く。
 * 呼ぶのは KalSetGeometry と配色エディタ・c キーから (どれも後で COMMIT を書く)。 */
static int spk_dark = 0;               /* 点滅で点を消している (色の表を黒にしている) */

static void SpkSet(void)
{
    const double c_per_px = (Z_CELL / TUBE_R) / (720.0 * 0.85 * set_zoom);
    int lv = (int)lround(log2(2.0 / (SPK_GAP_PX * c_per_px)));
    if (lv < 3) lv = 3;
    if (lv > 7) lv = 7;
    const double cell_px = 2.0 / (double)(1 << lv) / c_per_px;
    const double dot_px  = spk_size / 100.0;
    long k = lround((cell_px / dot_px) * (cell_px / dot_px) * 256.0);
    if (k < 0) k = 0;
    if (k > 65535) k = 65535;
    int dens  = spk_amount * 256 / 100;              /* 100% で 256 → 255 に切る */
    int base  = SPK_BASE  * spk_bright / 100;
    int flash = SPK_FLASH * spk_bright / 100;
    if (dens  > 255) dens  = 255;
    if (base  > 255) base  = 255;
    if (flash > 255) flash = 255;

    Xil_Out32(KAL_SPK_CTRL, (dens > 0 ? 1u : 0u) | ((u32)lv << 1) | ((u32)dens << 4));
    Xil_Out32(KAL_SPK_K,    (u32)k);
    Xil_Out32(KAL_SPK_GAIN, (u32)base | ((u32)flash << 8));
    SpkColors();
}

/* 配色エディタの SPARK の 8 色を、割合に応じて PL の色の表 16 個へ振り分けて書く。
 * 16 個の中の数 = 16 * 割合 / 合計 の整数部、余りは小数部の大きい色から 1 つずつ足す。
 * 点はハッシュで 16 個から等しく選ばれるので、割合は 1/16 (6.25%) 刻みになる。
 * 割合が全部 0 なら白にする */
static void SpkColors(void)
{
    const KindColor *kc = &cset[KIND_SPARK];
    u32 sum = 0;
    for (int j = 0; j < KCOLS; j++) sum += kc->rate[j];
    int cnt[KCOLS], rem[KCOLS], used = 0;
    for (int j = 0; j < KCOLS; j++) {
        const u32 x = (sum > 0) ? (u32)SPK_NCOL * kc->rate[j] : 0;
        cnt[j] = (sum > 0) ? (int)(x / sum) : 0;
        rem[j] = (sum > 0) ? (int)(x % sum) : 0;
        used += cnt[j];
    }
    while (sum > 0 && used < SPK_NCOL) {             /* 余りを小数部の大きい色へ */
        int best = 0;
        for (int j = 1; j < KCOLS; j++) if (rem[j] > rem[best]) best = j;
        cnt[best]++;  rem[best] = -1;  used++;
    }
    int slot = 0;
    for (int j = 0; j < KCOLS && slot < SPK_NCOL; j++)
        for (int m = 0; m < cnt[j] && slot < SPK_NCOL; m++, slot++) {
            const u32 v = spk_dark ? 0u
                        : ((u32)kc->rgb[j][0] << 16) | ((u32)kc->rgb[j][1] << 8) | kc->rgb[j][2];
            Xil_Out32(KAL_SPK_COL(slot), v);
        }
    for (; slot < SPK_NCOL; slot++) Xil_Out32(KAL_SPK_COL(slot), spk_dark ? 0u : 0xFFFFFFu);
}

/* 時刻を進める。毎フレーム COMMIT の前に呼ぶ (256 で 1 周)。
 * 配色エディタで SPARK を選んでいる間は、0.6 秒周期で点を消したり出したりする (点滅) */
static void SpkTick(void)
{
    Xil_Out32(KAL_SPK_TIME, (u32)lround(sim_time * SPK_SPEED / TWO_PI_D * 256.0) & 0xFF);
    const int dark = ed_on && ed_kind == KIND_SPARK && fmod(sim_time, 0.6) < 0.3;
    if (dark != spk_dark) {
        spk_dark = dark;
        SpkColors();
    }
}

static int InitDP(void)
{
    XDpPsu_Config *Cfg;
#ifndef SDT
    Cfg = XDpPsu_LookupConfig(DPPSU_DEVICE_ID);
#else
    Cfg = XDpPsu_LookupConfig(DPPSU_BASEADDR);
#endif
    if (!Cfg) return XST_FAILURE;

    XDpPsu_CfgInitialize(&DpPsu, Cfg, Cfg->BaseAddr);
#ifndef SDT
    XAVBuf_CfgInitialize(&AVBuf, DpPsu.Config.BaseAddr, AVBUF_DEVICE_ID);
#else
    XAVBuf_CfgInitialize(&AVBuf, DpPsu.Config.BaseAddr);
#endif

    u32 Status = XDpPsu_InitializeTx(&DpPsu);
    if (Status != XST_SUCCESS) {
        xil_printf("InitializeTx failed\r\n");
        return XST_FAILURE;
    }

    /* Live video input, no audio */
    XAVBuf_SetInputLiveVideoFormat(&AVBuf, RGB_12BPC);
    XAVBuf_SetOutputVideoFormat(&AVBuf, RGB_8BPC);
    XAVBuf_InputVideoSelect(&AVBuf, XAVBUF_VIDSTREAM1_LIVE, XAVBUF_VIDSTREAM2_NONE);
    XAVBuf_InputAudioSelect(&AVBuf, XAVBUF_AUDSTREAM1_NO_AUDIO, XAVBUF_AUDSTREAM2_NO_AUDIO);

    XDpPsu_MainStreamAttributes *Msa = &DpPsu.MsaConfig;
    XAVBuf_SetPixelClock(Msa->PixelClockHz);

    XAVBuf_ConfigureGraphicsPipeline(&AVBuf);
    XAVBuf_ConfigureOutputVideo(&AVBuf);
    XAVBuf_SetBlenderAlpha(&AVBuf, 0, 0);
    XDpPsu_CfgMsaEnSynchClkMode(&DpPsu, 0);
    XAVBuf_SetAudioVideoClkSrc(&AVBuf, XAVBUF_PS_CLK, XAVBUF_PL_CLK);
    XAVBuf_SoftReset(&AVBuf);

    return XST_SUCCESS;
}

static u32 TrainLink(void)
{
    u32 Status;
    XDpPsu_LinkConfig *Link = &DpPsu.LinkConfig;

    Status = XDpPsu_GetRxCapabilities(&DpPsu);
    if (Status != XST_SUCCESS) {
        xil_printf("GetRxCaps failed\r\n");
        return XST_FAILURE;
    }

    XDpPsu_SetEnhancedFrameMode(&DpPsu, Link->SupportEnhancedFramingMode ? 1 : 0);
    XDpPsu_SetLaneCount(&DpPsu, Link->MaxLaneCount);
    XDpPsu_SetLinkRate(&DpPsu, LINK_RATE_270);
    XDpPsu_SetDownspread(&DpPsu, Link->SupportDownspreadControl);

    xil_printf("Training: %d lanes, rate 0x%x\r\n", DpPsu.LinkConfig.LaneCount, DpPsu.LinkConfig.LinkRate);
    Status = XDpPsu_EstablishLink(&DpPsu);
    if (Status == XST_SUCCESS)
        xil_printf("Training OK\r\n");
    else
        xil_printf("Training failed\r\n");

    return Status;
}

static void SetupVideoStream(void)
{
    XDpPsu_SetColorEncode(&DpPsu, XDPPSU_CENC_RGB);
    XDpPsu_CfgMsaSetBpc(&DpPsu, XVIDC_BPC_8);
    XDpPsu_CfgMsaUseStandardVideoMode(&DpPsu, XVIDC_VM_1280x720_60_P);

    XDpPsu_MainStreamAttributes *Msa = &DpPsu.MsaConfig;
    XAVBuf_SetPixelClock(Msa->PixelClockHz);

    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, XDPPSU_SOFT_RESET, 0x1);
    usleep(10);
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, XDPPSU_SOFT_RESET, 0x0);

    XDpPsu_SetMsaValues(&DpPsu);
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, 0xB124, 0x3);
    usleep(10);
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, 0xB124, 0x0);

    XDpPsu_EnableMainLink(&DpPsu, 1);
    xil_printf("Video stream started\r\n");
}

static void RunDP(void)
{
    XDpPsu_EnableMainLink(&DpPsu, 0);

    if (!XDpPsu_IsConnected(&DpPsu)) {
        xil_printf("Not connected\r\n");
        return;
    }
    xil_printf("Connected\r\n");

    /* Wake up monitor */
    u8 AuxData = 0x1;
    XDpPsu_AuxWrite(&DpPsu, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &AuxData);
    XDpPsu_AuxWrite(&DpPsu, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &AuxData);

    /* TrainLink + SetupVideoStream を 1 回だけ実行する。
       XDpPsu_CheckLinkStatus のループは kv260_pong でも省略しており、
       入れるとハングすることがある。 */
    usleep(100000);
    if (TrainLink() == XST_SUCCESS) {
        SetupVideoStream();
    }
    xil_printf("RunDP returning\r\n");
}
