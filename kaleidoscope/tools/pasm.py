# -*- coding: utf-8 -*-
"""ピース演算器のアセンブラ。

`tools/piece_isa.py` に書いた 9 種のプログラムを、演算器が読む 64bit の
機械語に落とす。種類を足すときもここへプログラムを足すだけで、
出てきた .hex を AXI で書き込めば動く（再合成は要らない）。

【64bit の並び】
    [63:58] 命令        [57:53] 書き先 rd     [52:48] 読み元 ra
    [47:24] B  … 即値0、またはレジスタ番号 rb
    [23: 0] C  … 即値1、またはレジスタ番号 rc

【レジスタの割り当て】
    r0..r8 は入り口で決め打ち (qx qy vqx vqy seed z e rot time)。
    残り r9..r31 を、名前の「最後に使われる場所」を見て使い回す。
    天然石は名前が 42 個あるが、使い回すと 32 本に収まる。

【ATLEN と SINCOS】
    書き込み口が 1 本なので 2 命令に分ける。CORDIC を 2 回まわすことになるが
    レジスタファイルを 2 書き口にするより安い。

  使い方:  python tools/pasm.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import piece_isa as ISA
import kv_cell as K

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.join(HERE, "..", "rtl")

FRAC = 17
ONE = 1 << FRAC

OPS = {
    "NOP": 0, "MOV": 1, "LDI": 2, "ADD": 3, "SUB": 4, "MUL": 5, "MADD": 6,
    "ADDI": 7, "MULI": 8, "MADDI": 9, "MADDC": 10, "MIN": 11, "MAX": 12,
    "MINI": 13, "MAXI": 14, "ABS": 15, "NEG": 16, "FLOOR": 17, "CLAMP": 18,
    "LEN": 19, "ATAN": 20, "SIN": 21, "COS": 22,
    "RECIP": 23, "SQRT": 24, "POW": 25, "EXPN": 26, "SSTEP": 27, "SSTEPI": 28,
}

# 命令ごとの「引数の読み方」。r=レジスタ i=即値 -=無し
#   (ra, B, C)
FORM = {
    "MOV": ("r", "-", "-"), "LDI": ("-", "i", "-"),
    "ADD": ("r", "r", "-"), "SUB": ("r", "r", "-"), "MUL": ("r", "r", "-"),
    "MADD": ("r", "r", "r"),
    "ADDI": ("r", "i", "-"), "MULI": ("r", "i", "-"),
    "MADDI": ("r", "i", "i"), "MADDC": ("r", "i", "r"),
    "MIN": ("r", "r", "-"), "MAX": ("r", "r", "-"),
    "MINI": ("r", "i", "-"), "MAXI": ("r", "i", "-"),
    "ABS": ("r", "-", "-"), "NEG": ("r", "-", "-"), "FLOOR": ("r", "-", "-"),
    "CLAMP": ("r", "i", "i"),
    "LEN": ("r", "r", "-"), "ATAN": ("r", "r", "-"),
    "SIN": ("r", "-", "-"), "COS": ("r", "-", "-"),
    "RECIP": ("r", "-", "-"), "SQRT": ("r", "-", "-"),
    "POW": ("r", "i", "-"), "EXPN": ("r", "-", "-"),
    "SSTEP": ("r", "r", "r"), "SSTEPI": ("r", "i", "i"),
}

INPUTS = ["qx", "qy", "vqx", "vqy", "seed", "z", "e", "rot", "time"]
NREG = 32
OUTREG = {"A": 29, "K": 30, "W": 31}      # 出力は決まった場所に置く


def fx(v):
    """浮動小数点 → S6.17 の 24bit"""
    n = int(round(float(v) * ONE))
    if n > (1 << 23) - 1 or n < -(1 << 23):
        raise ValueError("S6.17 に入らない値 %r (%d)" % (v, n))
    return n & 0xFFFFFF


def expand(lines):
    """ATLEN と SINCOS を 2 命令に割る"""
    out = []
    for ln in lines:
        ln = ln.split("#")[0].strip()
        if not ln:
            continue
        op, _, rest = ln.partition(" ")
        f = [s.strip() for s in rest.split(",")] if rest.strip() else []
        if op.upper() == "ATLEN":
            out.append(("ATAN", [f[0], f[2], f[3]]))
            out.append(("LEN",  [f[1], f[2], f[3]]))
        elif op.upper() == "SINCOS":
            out.append(("SIN", [f[0], f[2]]))
            out.append(("COS", [f[1], f[2]]))
        else:
            out.append((op.upper(), f))
    return out


def allocate(instrs):
    """名前 → レジスタ番号。最後に使われたら空きに戻す"""
    # 各名前が最後に現れる命令番号
    last = {}
    for i, (op, f) in enumerate(instrs):
        form = FORM.get(op)
        names = []
        if op.startswith("OUT"):
            names = [f[0]]
        else:
            if form[0] == "r": names.append(f[1])
            if form[1] == "r": names.append(f[2])
            if form[2] == "r": names.append(f[3])
        for nm in names:
            last[nm] = i

    reg = {nm: i for i, nm in enumerate(INPUTS)}
    free = [i for i in range(len(INPUTS), NREG) if i not in OUTREG.values()]
    free.reverse()

    for i, (op, f) in enumerate(instrs):
        if op.startswith("OUT"):
            continue
        d = f[0]
        if d not in reg:
            if d in OUTREG:
                reg[d] = OUTREG[d]
            else:
                if not free:
                    raise RuntimeError("レジスタが足りない (命令 %d)" % i)
                reg[d] = free.pop()
        # この命令で最後になった名前を空きに戻す
        for nm, li in list(last.items()):
            if li == i and nm in reg and reg[nm] >= len(INPUTS) \
               and reg[nm] not in OUTREG.values() and nm != d:
                free.append(reg[nm])
                del last[nm]
    return reg


def assemble(key):
    src = ISA.program(key)
    instrs = expand(src)
    outs = {}
    body = []
    for op, f in instrs:
        if op in ("OUTA", "OUTK", "OUTW"):
            outs[op[-1]] = f[0]
        else:
            body.append((op, f))

    reg = allocate(body)
    # 出力は決まったレジスタに置く。違う名前なら MOV で移す
    for tag, nm in outs.items():
        if reg.get(nm) != OUTREG[tag]:
            body.append(("MOV", [tag, nm]))
            reg[tag] = OUTREG[tag]

    words = []
    meta = []          # 丸める前の即値を残す (アセンブラの検証用)
    for op, f in body:
        if op not in OPS:
            raise ValueError("知らない命令 %s" % op)
        form = FORM[op]
        d = reg[f[0]] if f[0] in reg else OUTREG.get(f[0], 0)
        if f[0] in OUTREG:
            d = OUTREG[f[0]]
        a = reg[f[1]] if form[0] == "r" else 0
        bi = 1 if form[0] == "-" else 2
        if form[1] == "r":
            B = reg[f[bi]]
        elif form[1] == "i":
            B = fx(f[bi])
        else:
            B = 0
        ci = bi + 1
        if form[2] == "r":
            C = reg[f[ci]]
        elif form[2] == "i":
            C = fx(f[ci])
        else:
            C = 0
        w = (OPS[op] << 58) | (d << 53) | (a << 48) | (B << 24) | C
        words.append(w)
        meta.append((op, d, a,
                     ("r", B) if form[1] == "r" else (("i", float(f[bi])) if form[1] == "i" else ("-", 0)),
                     ("r", C) if form[2] == "r" else (("i", float(f[ci])) if form[2] == "i" else ("-", 0))))
    return words, reg, meta


def main():
    order = ["bead", "glass", "glitter", "hexprism", "bubble",
             "stone", "rod", "blob", "crescent"]     # 種類番号の順
    base, length, mask = {}, {}, {}
    prog = []
    print("  種類        命令数  開始番地  毎画素の初期値")
    for key in order:
        w, reg, meta = assemble(key)
        t = K.KEY_TO_TYPE[key]
        base[t] = len(prog)
        length[t] = len(w)
        # プログラムが実際に読む入力 (r0=qx r1=qy r2=vqx r3=vqy) だけ印を立てる
        used = set()
        for op, d, a, (bK, B), (cK, C) in meta:
            form = FORM[op]
            if form[0] == "r": used.add(a)
            if bK == "r":      used.add(B)
            if cK == "r":      used.add(C)
        mask[t] = sum(1 << i for i in range(4) if i in used)
        nm = [n for n, v in {"qx": 0, "qy": 1, "vqx": 2, "vqy": 3}.items()
              if mask[t] & (1 << v)]
        print("  %-10s %4d  %7d   %s" % (key, len(w), len(prog), " ".join(sorted(nm))))
        prog += w

    path = os.path.join(RTL, "pprog.hex")
    with open(path, "w") as fp:
        for w in prog:
            fp.write("%016x\n" % w)
    print("\n  rtl/pprog.hex  %d 命令 x 64bit" % len(prog))

    tbl = os.path.join(RTL, "pprog_base.hex")
    with open(tbl, "w") as fp:
        for t in range(16):
            fp.write("%04x\n" % base.get(t, 0))
    print("  rtl/pprog_base.hex  種類 → 開始番地の表 (16 種ぶん)")

    with open(os.path.join(RTL, "pprog_len.hex"), "w") as fp:
        for t in range(16):
            fp.write("%04x\n" % length.get(t, 0))
    print("  rtl/pprog_len.hex   種類 → 命令数の表")

    # 毎画素レジスタへ入れるもの。bit0=qx(r0) bit1=qy(r1) bit2=vqx(r2) bit3=vqy(r3)
    # プログラムが実際に読むものだけ入れる。読まない値を入れるのは時間の無駄
    with open(os.path.join(RTL, "pprog_pre.hex"), "w") as fp:
        for t in range(16):
            fp.write("%01x\n" % mask.get(t, 0))
    print("  rtl/pprog_pre.hex   種類 → 毎画素入れるレジスタの印")


if __name__ == "__main__":
    main()
