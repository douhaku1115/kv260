# -*- coding: utf-8 -*-
"""USB コントローラの初期化を外した psu_init.tcl を作る (実機起動用)。

★★ USB (マウス・キーボード) を使うようにしたら、この方式は使えない。
   README の「実機の起動 (xsdb)」の「USB を使うとき」を読むこと。

なぜ要るか (2026-10-18 に突き止めた):
  この KV260 は QSPI から起動する。電源投入時に QSPI の U-Boot が USB の初期化に
  失敗する (No working controllers found) と、USB PHY からクロックが出ないことがある。
  その状態で psu_init が USB コントローラのレジスタ (0xFE20C200 GUSB2PHYCFG など) に
  書くとバスが固まり、FSBL が XFsbl_Exit に届かない (Vitis の
  "Failed to detect FSBL exit status" で止まる問題の正体)。
  万華鏡は USB を使わないので、その 4 行をコメントにして外す。

  使い方:  python tools/make_psu_nousb.py <元の psu_init.tcl> <出力>
  元は <Vitis WS>/kaleido_plat/export/kaleido_plat/hw/psu_init.tcl。
  PS の設定を変えた XSA にしたら作り直すこと。
"""
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="ascii", newline="").read().splitlines(keepends=True)
pat = re.compile(r"^(\s*)mask_write (0XFE2[0-9A-F]+) ")
out, hit = [], []
for ln in lines:
    m = pat.match(ln)
    if m:
        hit.append(m.group(2))
        ln = "%s# NO-USB: %s" % (m.group(1), ln.lstrip())
    out.append(ln)

# 外すのは USB0 コントローラの 4 行だけのはず。違ったら PS の設定が変わっているので止める
expect = ["0XFE20C200", "0XFE20C630", "0XFE20C11C", "0XFE20C12C"]
if hit != expect:
    print("★ 外す行が想定と違う: %s (想定 %s)。psu_init.tcl を見直すこと" % (hit, expect))
    sys.exit(1)
open(dst, "w", encoding="ascii", newline="").write("".join(out))
print("  %s  USB の %d 行を外した" % (dst, len(hit)))
