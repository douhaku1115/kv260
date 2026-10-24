""".nes を、PS のプログラムに埋め込む C ヘッダにする。

  python tools/rom2c.py ROM.nes   → vitis_src/rom_data.h
対応: マッパー 0/1/2/3/4/7、PRG 16〜256KB、CHR 8〜128KB (ROM か RAM)。解析は nesrom.py
ROM の中身が入るので rom_data.h は git に入れない (.gitignore 済)。
  rom_prg[]       PRG (ROM_PRG_SIZE バイト)
  rom_chr[]       CHR-ROM (ROM_CHR_SIZE バイト。CHR-RAM なら 0 で、配列は 1 バイトのダミー)
  ROM_CTRL        CTRL [15:0] の値 (実行ビット bit0 は main.c が足す)
"""
import sys
from pathlib import Path

from nesrom import load

prg, chr_, ctrl, desc = load(sys.argv[1])


def carray(name, data):
    lines = [",".join(f"0x{b:02X}" for b in data[i:i + 16]) for i in range(0, len(data), 16)]
    return f"static const uint8_t {name}[{max(len(data), 1)}] = {{\n" + (",\n".join(lines) or "0") + "\n};\n"


out = Path(__file__).resolve().parent.parent / "vitis_src" / "rom_data.h"
out.write_text(
    f"/* {Path(sys.argv[1]).name} から tools/rom2c.py で生成。git に入れない */\n"
    "#include <stdint.h>\n"
    f'#define ROM_NAME     "{Path(sys.argv[1]).stem}"\n'
    f"#define ROM_CTRL     0x{ctrl:04X}U\n"
    f"#define ROM_PRG_SIZE {len(prg)}\n"
    f"#define ROM_CHR_SIZE {len(chr_)}\n"
    + carray("rom_prg", prg) + carray("rom_chr", chr_))
print(f"{out}: {desc}")
