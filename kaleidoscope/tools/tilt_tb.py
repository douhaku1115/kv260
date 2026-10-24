# -*- coding: utf-8 -*-
"""視線の傾き (段9) の RTL 照合。sim/tb_scope_pipe.v と組で使う。

  python tools/tilt_tb.py gen <傾き> <方向 度> <間引き>   simbuild/tilt_par.hex を書く
  python tools/tilt_tb.py cmp <傾き> <方向 度> <間引き>   simbuild/tilt_out.txt とモデルを比べる

  間引き s: 縦横 s 画素おきに流す (s=1 で全画素)。
  比べるもの: 手前層の添字 fx, fy (CELL_BITS=8、回転なし)、反射回数、合わせ目、黒。
"""
import sys
import numpy as np
sys.path.insert(0, "tools")
import ref_scope as R
import fx_scope as F

CELL_BITS = 8
WORK = "simbuild/"


def params(mag, ang):
    v = F.view_matrix(mag * np.cos(np.radians(ang)), mag * np.sin(np.radians(ang)))
    walls, verts = R.mirror_geometry(R.POINTS)
    co = F.view_coefs(v, R.FOCAL)
    p = list(co)
    p += [int(round(R.Z_MIRROR * (1 << 16))),
          int(round((R.Z_CELL - R.Z_MIRROR) * (1 << F.Q_F))),
          int(round((1 << 16) / R.TUBE_R))]
    for w in walls:
        p += [int(F.to_fx(w[0], F.N_F, F.N_B)), int(F.to_fx(w[1], F.N_F, F.N_B)),
              int(F.to_fx(w[2], F.A_F, F.A_B))]
    for vt in verts:
        p += [int(F.to_fx(vt[0], F.P_F, F.P_B)), int(F.to_fx(vt[1], F.P_F, F.P_B))]
    p += [1 if R.MIRROR < 2.5 else 0]
    return v, p


def to_ix(c):
    u = c + (1 << F.P_F)
    sh = F.P_F + 1 - CELL_BITS
    return np.where(u < 0, 0, np.where(u >= (1 << (F.P_F + 1)), (1 << CELL_BITS) - 1, u >> sh))


def main():
    cmd, mag, ang, step = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
    v, p = params(mag, ang)
    if cmd == "gen":
        tgt = [int(sys.argv[5]), int(sys.argv[6])] if len(sys.argv) > 6 else []
        with open(WORK + "tilt_par.hex", "w") as f:
            for x in p + [step] + tgt:
                f.write("%08x\n" % (x & 0xFFFFFFFF))
        print("wrote", WORK + "tilt_par.hex", len(p) + 1, "words")
        return

    if len(sys.argv) > 6:
        F.TRACE = (int(sys.argv[6]), int(sys.argv[5]))   # (y, x)
    F.render(16, view=v)
    L = F.LAST
    ex = dict(fx=to_ix(L["cx"]), fy=to_ix(L["cy"]), nr=L["nrefl"], sm=L["seam"], bk=L["black"], cx=L["cx"], cy=L["cy"])
    ys, xs = np.mgrid[0:R.H:step, 0:R.W:step]
    exp = {k: a[ys, xs].ravel() for k, a in ex.items()}
    rows = [l.split() for l in open(WORK + "tilt_out.txt")]
    got = {k: np.array([int(r[i], 16) for r in rows]) for i, k in enumerate(("fx", "fy", "nr", "bk", "sm", "cx", "cy"))}
    for k in ("cx", "cy"):                            # 18 ビット符号付きに戻す
        got[k] = got[k] - ((got[k] >> 17) << 18)
    n = min(len(rows), exp["fx"].size)
    print("画素数 RTL %d / モデル %d" % (len(rows), exp["fx"].size))
    bk_e = exp["bk"][:n].astype(bool)
    bk_g = got["bk"][:n].astype(bool)
    print("黒の不一致 %d" % (bk_e != bk_g).sum())
    live = ~bk_e & ~bk_g                              # 黒の画素は添字を比べない
    # 前段 (setup) の出力
    try:
        srows = [l.split() for l in open(WORK + "tilt_setup.txt")]
        bits = dict(px=18, py=18, dx=F.DIR_B, dy=F.DIR_B)
        for i, k in enumerate(("px", "py", "dx", "dy")):
            g = np.array([int(r[i], 16) for r in srows[:n]])
            g = g - ((g >> (bits[k] - 1)) << bits[k])
            e = F.SETUP[k][ys, xs].ravel()[:n]
            bad = live & (e != g)
            print("setup %s 不一致 %d" % (k, bad.sum()))
    except FileNotFoundError:
        pass
    for k in ("fx", "fy", "nr", "sm", "cx", "cy"):
        bad = live & (exp[k][:n] != got[k][:n])
        print("%s 不一致 %d / %d" % (k, bad.sum(), live.sum()))
        if bad.any():
            i = np.flatnonzero(bad)[0]
            print("   最初: 番号 %d (x=%d y=%d) モデル %d RTL %d"
                  % (i, xs.ravel()[i], ys.ravel()[i], exp[k][i], got[k][i]))
            if len(rows[i]) > 5:
                cxr = int(rows[i][5], 16); cyr = int(rows[i][6], 16)
                cxr -= (cxr >> 17) << 18; cyr -= (cyr >> 17) << 18
                print("   c: モデル (%d, %d)  RTL (%d, %d)"
                      % (L["cx"][ys.ravel()[i], xs.ravel()[i]], L["cy"][ys.ravel()[i], xs.ravel()[i]], cxr, cyr))


if __name__ == "__main__":
    main()
