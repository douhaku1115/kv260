# -*- coding: utf-8 -*-
"""
万華鏡の折り返しを「Verilog にそのまま写せる形」の固定小数点で書いたモデル。

ref_scope.py (浮動小数点の正解) と見比べてビット幅を決めるのが目的。
ここで決めた形式と手順を rtl/scope_pipe.v に一対一で移す。

  使い方:  python tools/fx_scope.py [K] [出力PNG]

--- 設計の要点 ---------------------------------------------------------------
(1) 光線を正規化しない。
    p(z) = slope * z なので、媒介変数に z をそのまま使える。
    参照実装の sl = length(slope) / dir = slope/sl / remain = sl*(Z_CELL-Z_MIRROR)
    は、dir = slope, remain = Z_CELL - Z_MIRROR (全画素で同じ定数) と等価。
    平方根も正規化の除算も要らなくなる。

(2) 3枚の壁のうち一番近いものを選ぶのに除算は要らない。
    t_w = a_w / dn_w   (a_w = wd_w - dot(p,n_w), dn_w = dot(dir,n_w) > 0)
    t_i < t_j  <=>  a_i * dn_j < a_j * dn_i
    選ばれた1枚だけ除算する。段あたり除算1個で済む。

(3) 残り距離との比較も除算不要。  t < remain  <=>  a < remain * dn

--- 数の形式 -----------------------------------------------------------------
  p, dir   Q3.15  18bit 符号付き  (±4,  分解能 3.1e-5 cm)
  n        Q2.16  18bit 符号付き  (±2,  |n| = 1)
  a, wd    Q4.14  18bit 符号付き  (±8,  a = wd - dot(p,n) は最大 4.1)
  dn       Q3.15  18bit 符号付き
  q(=t)    Q6.14  20bit 符号なし  (0〜11.9)
  remain   Q6.14  20bit 符号なし
"""
import sys
import numpy as np
from PIL import Image
sys.path.insert(0, "tools")
import ref_scope as R
import seam_tables as ST

P_F, P_B = 15, 18       # p, dir
N_F, N_B = 16, 18       # 法線
A_F, A_B = 14, 18       # a, wd
D_F, D_B = 15, 18       # dn
Q_F, Q_B = 14, 20       # t, remain

RECIP_LUT_BITS = 9      # 逆数表 512 エントリ
RECIP_OUT_F = 17        # 表の値は Q1.17 (1/m, m in [0.5,1) なので 1〜2)


def sat(x, bits):
    lim = 1 << (bits - 1)
    return np.clip(x, -lim, lim - 1)


def to_fx(x, frac, bits):
    return sat(np.rint(np.asarray(x, dtype=np.float64) * (1 << frac)).astype(np.int64), bits)


# ---- 逆数表 (Verilog では BRAM) -------------------------------------------
# m を [0.5,1) に正規化した上位 RECIP_LUT_BITS ビットで引く
_idx = np.arange(1 << RECIP_LUT_BITS)
_m = 0.5 + (_idx + 0.5) / (1 << (RECIP_LUT_BITS + 1))
RECIP_LUT = np.rint(1.0 / _m * (1 << RECIP_OUT_F)).astype(np.int64)


def fx_div(a, dn):
    """q = a/dn を Q_F 形式で返す。a は Q A_F の正、dn は Q D_F の正。
       Verilog では: 優先エンコーダ -> 正規化シフト -> 表引き -> ニュートン1回。"""
    dn = np.maximum(dn, 1)

    # 先頭1の位置 nbits (dn = mant * 2^nbits, mant in [0.5,1))
    nbits = np.zeros_like(dn)
    x = dn.copy()
    for b in range(D_B):
        nbits = np.where(x > 0, b + 1, nbits)
        x = x >> 1

    mant = (dn << 31) >> nbits                       # Q31 の [0.5,1)。最上位ビットは常に 1
    # 表は最上位ビットの「下」の 9 ビットで引く (m = 0.5 + idx/1024)
    idx = (mant >> (30 - RECIP_LUT_BITS)) & ((1 << RECIP_LUT_BITS) - 1)
    y0 = RECIP_LUT[idx]                              # Q RECIP_OUT_F

    # ニュートン1回:  y1 = y0 * (2 - mant*y0)
    my = (mant * y0) >> 31                           # Q RECIP_OUT_F
    y1 = (y0 * ((2 << RECIP_OUT_F) - my)) >> RECIP_OUT_F

    # 1/dn = y1 / 2^RECIP_OUT_F * 2^(D_F - nbits)
    # q = a / 2^A_F * (1/dn) * 2^Q_F
    prod = a * y1
    sh = A_F + RECIP_OUT_F - Q_F - (D_F - nbits)
    q = np.where(sh >= 0, prod >> np.maximum(sh, 0), prod << np.maximum(-sh, 0))
    return np.clip(q, 0, (1 << Q_B) - 1)


def render(K=16):
    walls, verts = R.mirror_geometry(R.POINTS)
    VX = to_fx([v[0] for v in verts], P_F, P_B)
    VY = to_fx([v[1] for v in verts], P_F, P_B)
    SEAM_LUT = np.array(ST.seam_lut(), dtype=np.int64)
    NX = to_fx([w[0] for w in walls], N_F, N_B)
    NY = to_fx([w[1] for w in walls], N_F, N_B)
    WD = to_fx([w[2] for w in walls], A_F, A_B)

    W, H = R.W, R.H
    px, py = np.meshgrid(np.arange(W), np.arange(H))
    spx = (px + 0.5 - 0.5 * W) / H
    spy = (0.5 * H - (py + 0.5)) / H

    # 傾き 0 のときは slope = sp / focal (除算不要。PS が 1/focal を渡す)
    slx = to_fx(spx / R.FOCAL, P_F, P_B)
    sly = to_fx(spy / R.FOCAL, P_F, P_B)

    zm = int(round(R.Z_MIRROR * (1 << 16)))
    px_ = sat((slx * zm) >> 16, P_B)                 # p = slope * Z_MIRROR
    py_ = sat((sly * zm) >> 16, P_B)
    dx, dy = slx.copy(), sly.copy()

    remain = np.full(px_.shape, int(round((R.Z_CELL - R.Z_MIRROR) * (1 << Q_F))), dtype=np.int64)
    nrefl = np.zeros(px_.shape, dtype=np.int64)
    seam = np.full(px_.shape, 1 << ST.SEAM_F, dtype=np.int64)
    done = np.zeros(px_.shape, dtype=bool)

    # 三角形の外 (筒の縁) は黒
    black = np.zeros(px_.shape, dtype=bool)
    for w in range(3):
        dot = (px_ * NX[w] + py_ * NY[w]) >> (P_F + N_F - A_F)
        black |= dot > WD[w]
    done |= black

    for stage in range(K):
        a = np.stack([sat(WD[w] - ((px_ * NX[w] + py_ * NY[w]) >> (P_F + N_F - A_F)), A_B)
                      for w in range(3)], -1)
        dn = np.stack([sat((dx * NX[w] + dy * NY[w]) >> (P_F + N_F - D_F), D_B)
                       for w in range(3)], -1)
        a = np.maximum(a, 0)
        cand = dn > 0

        # 最小の t を持つ壁を選ぶ (除算なし)
        best = np.zeros(px_.shape, dtype=np.int64)
        has = cand[..., 0].copy()
        for w in (1, 2):
            ab = np.take_along_axis(a, best[..., None], -1)[..., 0]
            db = np.take_along_axis(dn, best[..., None], -1)[..., 0]
            better = cand[..., w] & (~has | (a[..., w] * db < ab * dn[..., w]))
            best = np.where(better, w, best)
            has |= cand[..., w]

        a_s = np.take_along_axis(a, best[..., None], -1)[..., 0]
        dn_s = np.take_along_axis(dn, best[..., None], -1)[..., 0]

        # t >= remain か? (除算なし)  a >= remain * dn
        over = (a_s << (Q_F + D_F - A_F)) >= remain * dn_s
        fin = (~done) & (~has | over)

        # 終端画素: 残り距離ぶん直進
        px_ = np.where(fin, sat(px_ + ((dx * remain) >> Q_F), P_B), px_)
        py_ = np.where(fin, sat(py_ + ((dy * remain) >> Q_F), P_B), py_)
        done |= fin

        hit = ~done
        if not hit.any():
            break

        q = fx_div(a_s, np.maximum(dn_s, 1))
        px_ = np.where(hit, sat(px_ + ((dx * q) >> Q_F), P_B), px_)
        py_ = np.where(hit, sat(py_ + ((dy * q) >> Q_F), P_B), py_)
        remain = np.where(hit, np.maximum(remain - q, 0), remain)

        if R.MIRROR < 2.5:
            bottom = hit & (best == 2)
            black |= bottom
            done |= bottom
            hit &= ~bottom

        # 鏡の合わせ目: 頂点に近いほど暗い線になる
        dv2 = np.min(np.stack([(((px_ - VX[v]) ** 2 + (py_ - VY[v]) ** 2) >> (2*P_F - ST.DV2_F))
                               for v in range(3)], -1), -1)
        u2 = np.clip((dv2 * ST.inv_e2(stage)) >> ST.U2_SHIFT, 0, (1 << ST.U2_F))
        f = SEAM_LUT[np.minimum(u2 >> (ST.U2_F - ST.SEAM_LUT_BITS), (1 << ST.SEAM_LUT_BITS) - 1)]
        seam = np.where(hit, (seam * f) >> ST.SEAM_OUT_F, seam)

        nsx = NX[best]
        nsy = NY[best]
        two_dn = dn_s << 1
        ndx = sat(dx - ((two_dn * nsx) >> N_F), P_B)
        ndy = sat(dy - ((two_dn * nsy) >> N_F), P_B)
        dx = np.where(hit, ndx, dx)
        dy = np.where(hit, ndy, dy)
        nrefl = np.where(hit, nrefl + 1, nrefl)

    # 反射上限に達した画素も残りを進める
    px_ = np.where(~done, sat(px_ + ((dx * remain) >> Q_F), P_B), px_)
    py_ = np.where(~done, sat(py_ + ((dy * remain) >> Q_F), P_B), py_)

    # セル座標 c = p / TUBE_R  ->  テクスチャ添字 (0..CELL_N-1)
    n = R.CELL_N
    inv_tr = int(round((1 << 16) / R.TUBE_R))
    cx = (px_ * inv_tr) >> 16                        # Q P_F の [-1,1]
    cy = (py_ * inv_tr) >> 16
    ix = np.clip(((cx + (1 << P_F)) * n) >> (P_F + 1), 0, n - 1)
    iy = np.clip(((cy + (1 << P_F)) * n) >> (P_F + 1), 0, n - 1)

    cell = R.make_test_cell(n)
    col = cell[iy, ix]

    col = col * (R.LOSS ** nrefl)[..., None] * (seam / float(1 << ST.SEAM_F))[..., None]
    col = np.where(black[..., None], np.array([0.01, 0.009, 0.013]), col)
    col = col * (1.0 - 0.3 * (spx ** 2 + spy ** 2))[..., None]
    return np.clip(col, 0, 1), nrefl


if __name__ == "__main__":
    K = int(sys.argv[1]) if len(sys.argv) > 1 else 16
    out = sys.argv[2] if len(sys.argv) > 2 else "sim/fx_scope_K%d.png" % K
    img, nr = render(K)
    Image.fromarray((img * 255 + 0.5).astype(np.uint8)).save(out)
    print("wrote", out)

    ref = R.render()
    d = np.abs(img - ref)
    bad = (d.max(-1) > 8.0 / 255).mean()
    print("K=%d  平均誤差 %.3f/255  最大 %.1f/255  8/255超の画素 %.2f%%"
          % (K, d.mean() * 255, d.max() * 255, bad * 100))
