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

P_F, P_B = 15, 18       # p (光線は三角形の中にとどまるので ±4 で足りる)
DIR_B = 20              # dir (段9: 傾けると slope が最大 6.75 になるので 18→20 ビット、±16)
N_F, N_B = 16, 18       # 法線
A_F, A_B = 14, 18       # a, wd
D_F, D_B = 15, 20       # dn (= dot(dir, n) なので dir と同じ 20 ビット)
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

    # rtl/divq.v と同じく仮数を 18 ビット (mn) に切り詰めてから Q31 に並べる
    mn = np.where(nbits <= 18, dn << np.maximum(18 - nbits, 0), dn >> np.maximum(nbits - 18, 0))
    mant = mn << 13                                  # Q31 の [0.5,1)。最上位ビットは常に 1
    # 表は最上位ビットの「下」の 9 ビットで引く (m = 0.5 + idx/1024)
    idx = (mant >> (30 - RECIP_LUT_BITS)) & ((1 << RECIP_LUT_BITS) - 1)
    y0 = RECIP_LUT[idx]                              # Q RECIP_OUT_F

    # ニュートン1回:  y1 = y0 * (2 - mant*y0)
    my = (mant * y0) >> 31                           # Q RECIP_OUT_F
    y1 = np.minimum((y0 * ((2 << RECIP_OUT_F) - my)) >> RECIP_OUT_F, (1 << 19) - 1)

    # 1/dn = y1 / 2^RECIP_OUT_F * 2^(D_F - nbits)
    # q = a / 2^A_F * (1/dn) * 2^Q_F
    prod = a * y1
    sh = A_F + RECIP_OUT_F - Q_F - (D_F - nbits)
    q = np.where(sh >= 0, prod >> np.maximum(sh, 0), prod << np.maximum(-sh, 0))
    return np.clip(q, 0, (1 << Q_B) - 1)


def view_matrix(tx, ty):
    """参照実装 (ref/mirrorGeometry.js) の viewMatrix。列が r, up, f の 3x3 (rd = M @ (sx, sy, focal))"""
    a = np.hypot(tx, ty)
    s = 1.0 if a < 1e-6 else np.sin(a) / a
    f = np.array([tx * s, ty * s, np.cos(a)])
    r = np.array([f[2], 0.0, -f[0]])
    r /= np.hypot(r[0], r[2])
    up = np.cross(f, r)
    return np.stack([r, up, f], axis=1)


# 視線の傾き (段9)。slope = rd.xy / rd.z を画素ごとに作る (rtl/scope_pipe.v の setup S1〜S7)
#   rd = r*sx + up*sy + f*focal、sx = hn/1440、sy = vn/1440 (hn = 2h-1279、vn = 719-2v。上向き正)
#   1440 倍した  N = a*hn + b*vn + c  を x / y / z の 3 本作る。
#     a, b: Q16 18 ビット (PS が渡す)、c: Q16 32 ビット (focal*1440 を含む。最大 2^28)
#   dir = Nx / Nz は、Nz の仮数 24 ビットを逆数表 + ニュートン 1 回で 1/Nz にして掛ける。
#   Nz <= 0 (後ろ向き) は黒。傾き 0 でもこの道を通る (kx の掛け算は使わない)
CO_F = 16                 # 係数 a, b, c の小数部
MN_B = 24                 # Nz を正規化した仮数のビット数
NS_SH = 22                # Nx を Nz と同じだけ縮めるときの基準 (Nx_s = Nx >> (nb - NS_SH))
NS_B = 27                 # Nx_s の幅 (符号付き)


def view_coefs(view, focal):
    """PS が書く 9 個の係数 (ax, bx, cx, ay, by, cy, az, bz, cz)"""
    M = np.asarray(view, dtype=np.float64)
    co = []
    for row in range(3):                             # rd[row] = M[row,0]*sx + M[row,1]*sy + M[row,2]*focal
        co += [int(round(M[row, 0] * (1 << CO_F))),
               int(round(M[row, 1] * (1 << CO_F))),
               int(round(M[row, 2] * focal * 1440 * (1 << CO_F)))]
    return co


def fx_slope(co, W, H):
    """dir (Q P_F、DIR_B ビット) と「後ろ向き (Nz <= 0)」の印を返す"""
    px, py = np.meshgrid(np.arange(W), np.arange(H))
    hn = (2 * px - 1279).astype(np.int64)
    vn = (719 - 2 * py).astype(np.int64)
    N = [co[3*r] * hn + co[3*r+1] * vn + co[3*r+2] for r in range(3)]   # S1
    Nz = N[2]
    back = Nz <= 0
    d = np.maximum(Nz, 1)
    nb = np.zeros_like(d)                            # S2: 先頭 1 の位置 (1 始まり)
    x = d.copy()
    for b in range(31):
        nb = np.where(x > 0, b + 1, nb)
        x = x >> 1
    # S3: 仮数 mn ∈ [2^23, 2^24) と、同じだけ縮めた Nx_s, Ny_s (27 ビットで飽和)
    mn = np.where(nb <= MN_B, d << np.maximum(MN_B - nb, 0), d >> np.maximum(nb - MN_B, 0))
    ns = [sat(np.where(nb >= NS_SH, n >> np.maximum(nb - NS_SH, 0), n << np.maximum(NS_SH - nb, 0)), NS_B)
          for n in N[:2]]
    y0 = RECIP_LUT[(mn >> (MN_B - 1 - RECIP_LUT_BITS)) & ((1 << RECIP_LUT_BITS) - 1)]   # S4
    my = (mn * y0) >> MN_B                                                              # S5
    y1 = np.minimum((y0 * ((2 << RECIP_OUT_F) - my)) >> RECIP_OUT_F, (1 << 19) - 1)    # S6
    # S7: 1/Nz = y1 / 2^17 / 2^nb、Nx = Nx_s * 2^(nb-22) なので dir*2^15 = Nx_s*y1 / 2^24
    sh = RECIP_OUT_F + NS_SH - P_F                   # = 24
    return sat((ns[0] * y1) >> sh, DIR_B), sat((ns[1] * y1) >> sh, DIR_B), back


TRACE = None              # (y, x) を入れると、その画素の段ごとの値を表示する (RTL 照合用)


def render(K=16, view=None, focal=None):
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

    focal = R.FOCAL if focal is None else focal
    if view is None:
        view = np.eye(3)
    slx, sly, back = fx_slope(view_coefs(view, focal), W, H)

    zm = int(round(R.Z_MIRROR * (1 << 16)))
    # p = slope * Z_MIRROR。三角形の外かを見るまでは DIR_B ビットで持つ (18 ビットだと巻き戻って
    # 外の画素が内側に化ける)。内側なら 18 ビットに収まる
    px_ = sat((slx * zm) >> 16, DIR_B)
    py_ = sat((sly * zm) >> 16, DIR_B)
    dx, dy = slx.copy(), sly.copy()

    remain = np.full(px_.shape, int(round((R.Z_CELL - R.Z_MIRROR) * (1 << Q_F))), dtype=np.int64)
    nrefl = np.zeros(px_.shape, dtype=np.int64)
    seam = np.full(px_.shape, 1 << ST.SEAM_F, dtype=np.int64)
    done = np.zeros(px_.shape, dtype=bool)

    # 三角形の外 (筒の縁) は黒
    black = back.copy()                              # 後ろ向きの視線も黒
    for w in range(3):
        dot = (px_ * NX[w] + py_ * NY[w]) >> (P_F + N_F - A_F)
        black |= dot > WD[w]
    done |= black
    px_ = np.where(black, 0, px_)                    # 内側の画素は 18 ビットに収まっている
    py_ = np.where(black, 0, py_)
    global SETUP
    SETUP = dict(px=px_.copy(), py=py_.copy(), dx=dx.copy(), dy=dy.copy())   # RTL 照合用

    for stage in range(K):
        if TRACE is not None:
            ty, tx = TRACE
            print("段 %d: p=(%d,%d) d=(%d,%d) rm=%d nr=%d done=%d" % (
                stage, px_[ty, tx], py_[ty, tx], dx[ty, tx], dy[ty, tx],
                remain[ty, tx], nrefl[ty, tx], done[ty, tx]))
        a = np.stack([sat(WD[w] - ((px_ * NX[w] + py_ * NY[w]) >> (P_F + N_F - A_F)), A_B)
                      for w in range(3)], -1)
        dn = np.stack([sat((dx * NX[w] + dy * NY[w]) >> (P_F + N_F - D_F), D_B)
                       for w in range(3)], -1)
        a = np.maximum(a, 0)
        cand = dn > 0

        # 最小の t を持つ壁を選ぶ (除算なし)。同点の決め方まで rtl/scope_stage.v の T1 と同じ式
        #   (光線が三角形の頂点にちょうど当たると 2 枚の t が等しくなる)
        c0, c1, c2 = cand[..., 0], cand[..., 1], cand[..., 2]
        t01 = a[..., 0] * dn[..., 1] < a[..., 1] * dn[..., 0]
        t02 = a[..., 0] * dn[..., 2] < a[..., 2] * dn[..., 0]
        t12 = a[..., 1] * dn[..., 2] < a[..., 2] * dn[..., 1]
        sel0 = c0 & (~c1 | t01) & (~c2 | t02)
        sel1 = ~sel0 & c1 & (~c0 | ~t01) & (~c2 | t12)
        best = np.where(sel0, 0, np.where(sel1, 1, 2))
        has = c0 | c1 | c2

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
        ndx = sat(dx - ((two_dn * nsx) >> N_F), DIR_B)
        ndy = sat(dy - ((two_dn * nsy) >> N_F), DIR_B)
        dx = np.where(hit, ndx, dx)
        dy = np.where(hit, ndy, dy)
        nrefl = np.where(hit, nrefl + 1, nrefl)

    # 反射上限に達した画素は黒 (直進させると筒の外を引いて明るい筋になる。段9)
    black |= ~done

    # セル座標 c = p / TUBE_R  ->  テクスチャ添字 (0..CELL_N-1)
    n = R.CELL_N
    inv_tr = int(round((1 << 16) / R.TUBE_R))
    cx = (px_ * inv_tr) >> 16                        # Q P_F の [-1,1]
    cy = (py_ * inv_tr) >> 16
    ix = np.clip(((cx + (1 << P_F)) * n) >> (P_F + 1), 0, n - 1)
    iy = np.clip(((cy + (1 << P_F)) * n) >> (P_F + 1), 0, n - 1)

    # RTL との照合用 (tools/tilt_tb.py)
    global LAST
    LAST = dict(cx=cx, cy=cy, nrefl=nrefl, seam=seam, black=black)

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
