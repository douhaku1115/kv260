"""NROM の .nes を、PS のプログラムに埋め込む C ヘッダにする。

  python tools/rom2c.py ROM.nes   → vitis_src/rom_data.h
ROM の中身が入るので rom_data.h は git に入れない (.gitignore 済)。
  rom_prg[32768]  PRG。16KB なら 2 回並べて 32KB にする (CTRL bit1 は使わない)
  rom_chr[8192]   CHR。CHR-RAM (CHR 0 個) なら 0
  ROM_MIRROR_V    1 = 垂直ミラー (CTRL bit2)
"""
import sys
from pathlib import Path

src = Path(sys.argv[1])
rom = src.read_bytes()
if rom[:4] != b"NES\x1a":
    sys.exit("先頭が NES\\x1a ではない")
mapper = (rom[6] >> 4) | (rom[7] & 0xF0)
if mapper != 0:
    sys.exit(f"マッパー {mapper} は未対応 (NROM だけ)")
if rom[6] & 0x04:
    sys.exit("トレーナー付きは未対応")

n_prg, n_chr = rom[4], rom[5]
prg = rom[16:16 + n_prg * 16384]
if len(prg) == 16384:
    prg = prg * 2
if len(prg) != 32768:
    sys.exit(f"PRG が 16KB/32KB でない ({len(prg)})")
chr_ = rom[16 + n_prg * 16384:16 + n_prg * 16384 + n_chr * 8192] if n_chr else bytes(8192)


def carray(name, data):
    lines = [",".join(f"0x{b:02X}" for b in data[i:i + 16]) for i in range(0, len(data), 16)]
    return f"static const uint8_t {name}[{len(data)}] = {{\n" + ",\n".join(lines) + "\n};\n"


out = Path(__file__).resolve().parent.parent / "vitis_src" / "rom_data.h"
out.write_text(
    f"/* {src.name} から tools/rom2c.py で生成。git に入れない */\n"
    "#include <stdint.h>\n"
    f'#define ROM_NAME     "{src.stem}"\n'
    f"#define ROM_MIRROR_V {rom[6] & 1}\n"
    + carray("rom_prg", prg) + carray("rom_chr", chr_))
print(f"{out}: {src.name} PRG {n_prg}x16KB CHR {n_chr}x8KB")
