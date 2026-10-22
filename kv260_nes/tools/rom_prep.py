"""NROM の .nes を、テストベンチ tb_rom が $readmemh で読める形にする。

  python tools/rom_prep.py ROM.nes [フレーム数] [ボタン(16進) 押すフレーム]
出力 (roms/ の下、git に入れない):
  rom_prg.hex  PRG 32KB を 1 行 4 バイト (8192 行)。16KB なら 2 回並べる
  rom_chr.hex  CHR 8KB を 1 行 1 バイト。CHR-RAM (CHR 0 個) なら 0 で埋める
  rom_cfg.hex  1 行目 = CTRL の bit2 (垂直ミラー) / 2 行目 = 回すフレーム数
               3 行目 = 押すボタン (PAD の並び。0 = 押さない) / 4 行目 = 押し始めるフレーム
               (tb_rom は 5 フレーム押して離す)
"""
import sys
from pathlib import Path

ROMS = Path(__file__).resolve().parent.parent / "roms"

src = Path(sys.argv[1])
nframes = int(sys.argv[2]) if len(sys.argv) > 2 else 60
pad = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0
press = int(sys.argv[4]) if len(sys.argv) > 4 else 0
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
chr_ = rom[16 + n_prg * 16384:16 + n_prg * 16384 + n_chr * 8192]
if n_chr == 0:
    chr_ = bytes(8192)
mirror_v = rom[6] & 1

(ROMS / "rom_prg.hex").write_text(
    "".join(f"{int.from_bytes(prg[i:i + 4], 'little'):08X}\n" for i in range(0, 32768, 4)))
(ROMS / "rom_chr.hex").write_text("".join(f"{b:02X}\n" for b in chr_))
(ROMS / "rom_cfg.hex").write_text(f"{mirror_v << 2:08X}\n{nframes:08X}\n{pad:08X}\n{press:08X}\n")
print(f"{src.name}: PRG {n_prg}x16KB CHR {n_chr}x8KB {'垂直' if mirror_v else '水平'}ミラー {nframes} フレーム"
      + (f" / ボタン {pad:02X} をフレーム {press} で押す" if pad else ""))
