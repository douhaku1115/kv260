""".nes を、PS のプログラムに埋め込む C ヘッダにする。複数渡すと main.c のメニューで選べる。

  python tools/rom2c.py ROM.nes [ROM2.nes ...]   → vitis_src/rom_data.h
対応: マッパー 0/1/2/3/4/7、PRG 16〜256KB、CHR 8〜128KB (ROM か RAM)。解析は nesrom.py
ROM の中身が入るので rom_data.h は git に入れない (.gitignore 済)。
  romN_prg[] / romN_chr[]  N 本目の PRG / CHR-ROM (CHR-RAM なら CHR は 0 バイトで、配列は 1 バイトのダミー)
  roms[ROM_COUNT]          名前 (ファイル名から。_ は空白)・CTRL [15:0] の値 (実行ビット bit0 は main.c が足す)・
                           PRG / CHR の場所と大きさ
同じ名前のファイル (中身も同じ写し) は 1 本にまとめる。
"""
import sys
from pathlib import Path

from nesrom import load


def carray(name, data):
    lines = [",".join(f"0x{b:02X}" for b in data[i:i + 16]) for i in range(0, len(data), 16)]
    return f"static const uint8_t {name}[{max(len(data), 1)}] = {{\n" + (",\n".join(lines) or "0") + "\n};\n"


paths, seen = [], set()
for a in sys.argv[1:]:
    p = Path(a)
    if p.name.lower() in seen:
        continue
    seen.add(p.name.lower())
    paths.append(p)
if not paths:
    sys.exit("usage: rom2c.py ROM.nes [ROM2.nes ...]")

body, table = [], []
for n, p in enumerate(paths):
    prg, chr_, ctrl, desc = load(str(p))
    name = p.stem.replace("_", " ")[:28]
    body.append(carray(f"rom{n}_prg", prg) + carray(f"rom{n}_chr", chr_))
    table.append(f'    {{"{name}", 0x{ctrl:04X}U, rom{n}_prg, {len(prg)}, rom{n}_chr, {len(chr_)}}},')
    print(f"{n}: {p.name}: {desc}")

out = Path(__file__).resolve().parent.parent / "vitis_src" / "rom_data.h"
out.write_text(
    "/* tools/rom2c.py で生成。git に入れない */\n"
    "#include <stdint.h>\n"
    "struct rom_entry {\n"
    "    const char *name;       /* メニューに出す名前 */\n"
    "    uint32_t ctrl;          /* CTRL [15:0] */\n"
    "    const uint8_t *prg; uint32_t prg_size;\n"
    "    const uint8_t *chr; uint32_t chr_size;   /* CHR-RAM なら 0 */\n"
    "};\n"
    f"#define ROM_COUNT {len(paths)}\n"
    + "".join(body)
    + "static const struct rom_entry roms[ROM_COUNT] = {\n" + "\n".join(table) + "\n};\n",
    encoding="utf-8")
print(f"{out}: {len(paths)} 本")
