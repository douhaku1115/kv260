"""nestest の ROM と正解ログを、テストベンチが $readmemh で読める形にする。

  python tools/nestest_prep.py
入力: roms/nestest.nes, roms/nestest.log
出力: roms/nestest_prg.hex  PRG 16KB (1 行 1 バイト)
      roms/nestest_exp.hex  公式命令の各行を 88bit に詰めたもの
                            {CYC[31:0], PC[15:0], A, X, Y, P, SP}
      照合は最初の非公式命令 ('*' 印) の手前まで。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROMS = ROOT / "roms"

rom = (ROMS / "nestest.nes").read_bytes()
if rom[:4] != b"NES\x1a":
    sys.exit("nestest.nes の先頭が NES\\x1a ではない")
prg_banks = rom[4]
prg = rom[16:16 + prg_banks * 16384]
if len(prg) != 16384:
    sys.exit(f"PRG が 16KB でない ({len(prg)})")
(ROMS / "nestest_prg.hex").write_text("".join(f"{b:02X}\n" for b in prg))

pat = re.compile(r"^([0-9A-F]{4})  (.{8}) ([ *])\w{3}.*"
                 r"A:([0-9A-F]{2}) X:([0-9A-F]{2}) Y:([0-9A-F]{2}) P:([0-9A-F]{2}) SP:([0-9A-F]{2}).*CYC:(\d+)")
out = []
for n, line in enumerate((ROMS / "nestest.log").read_text().splitlines(), 1):
    m = pat.match(line)
    if not m:
        sys.exit(f"{n} 行目を読めない: {line}")
    if m.group(3) == "*":
        print(f"非公式命令が {n} 行目に出たのでここまで ({len(out)} 命令)")
        break
    pc, a, x, y, p, sp, cyc = m.group(1, 4, 5, 6, 7, 8, 9)
    out.append(f"{int(cyc):08X}{pc}{a}{x}{y}{p}{sp}")
(ROMS / "nestest_exp.hex").write_text("\n".join(out) + "\n")
print(f"PRG {len(prg)} バイト / 期待値 {len(out)} 行")
