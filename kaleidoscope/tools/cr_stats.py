# -*- coding: utf-8 -*-
"""押し合いの当たり判定 cr = r * type_cr の分布を数える (物理演算の高速化の下調べ)。

vitis_src/parts_data.c を読み、種類ごとの個数と cr の範囲、
マスの一辺 (cr の最大の 2 倍) を出す。

  使い方:  python tools/cr_stats.py
"""
import os
import re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
# main.c の type_cr と同じ (番号は kv_cell.py)
TYPE_CR = [1.00, 0.85, 0.00, 0.50, 1.00, 1.00, 0.45, 0.90, 0.70]
TYPE_NAME = ["bead", "glass", "glitter", "hexprism", "bubble", "stone", "rod", "blob", "crescent"]

src = open(os.path.join(ROOT, "vitis_src", "parts_data.c"), encoding="utf-8").read()
body = src.split("const Part parts[NPARTS] = {", 1)[1].split("};", 1)[0]
rows = re.findall(r"\{(\d+), (\d+), \d+, \d+, \{[^}]*\}, ([^,]+), ([^,]+), ([^,]+), ([^,]+),", body)

by = {}
crs = []
for typ, kind, x, y, z, r in rows:
    t = int(typ) % 9 if int(typ) >= 9 else int(typ)
    cr = float(r) * TYPE_CR[t] if int(typ) < 9 else None
    by.setdefault(int(typ), []).append((float(r), cr))
    if cr:
        crs.append(cr)

print("ピース %d 個" % len(rows))
for typ in sorted(by):
    rs = [a for a, _ in by[typ]]
    cs = [c for _, c in by[typ] if c]
    name = TYPE_NAME[typ] if typ < 9 else "typ%d" % typ
    if cs:
        print("  %-9s %4d 個  r %.4f〜%.4f  cr %.4f〜%.4f" % (name, len(rs), min(rs), max(rs), min(cs), max(cs)))
    else:
        print("  %-9s %4d 個  r %.4f〜%.4f  (当たり判定なし)" % (name, len(rs), min(rs), max(rs)))

crs.sort()
print("当たり判定あり %d 個。cr の最大 %.4f → マスの一辺 %.4f (16 分割なら %.4f)"
      % (len(crs), crs[-1], 2 * crs[-1], 2.0 / 16))
for q in (0.5, 0.8, 0.9, 0.95, 0.99):
    print("  cr の %d%% 点: %.4f" % (q * 100, crs[int(q * (len(crs) - 1))]))
