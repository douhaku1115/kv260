"""iNES / NES 2.0 の .nes を読み、PL に入れる形 (PRG / CHR と CTRL の値) にする。

rom_prep.py (sim 用) と rom2c.py (PS 用) が使う。
CTRL [15:0] (rtl/mapper.v と同じ):
  [2] 垂直ミラー  [3] CHR-RAM  [7:4] マッパー番号
  [11:8] PRG の 16KB 個数 - 1  [15:12] CHR の 8KB 個数 - 1
"""
import sys
from pathlib import Path

MAPPERS = {0: "NROM", 1: "MMC1", 2: "UxROM", 3: "CNROM", 4: "MMC3", 7: "AxROM"}


def load(path):
    rom = Path(path).read_bytes()
    if rom[:4] != b"NES\x1a":
        sys.exit("先頭が NES\\x1a ではない")
    nes2 = (rom[7] & 0x0C) == 0x08
    mapper = (rom[6] >> 4) | (rom[7] & 0xF0)
    if mapper not in MAPPERS:
        sys.exit(f"マッパー {mapper} は未対応 (対応: {sorted(MAPPERS)})")
    if rom[6] & 0x04:
        sys.exit("トレーナー付きは未対応")
    if rom[6] & 0x08:
        print("注意: 4 画面ネームテーブルは未対応 (水平/垂直として動かす)")

    n_prg, n_chr = rom[4], rom[5]
    if n_prg not in (1, 2, 4, 8, 16):
        sys.exit(f"PRG {n_prg}x16KB は未対応 (16〜256KB の 2 のべき乗)")
    prg = rom[16:16 + n_prg * 16384]
    if len(prg) != n_prg * 16384:
        sys.exit("PRG が途中で切れている")

    if n_chr:
        chr_ram = False
        chr_ = rom[16 + n_prg * 16384:16 + n_prg * 16384 + n_chr * 8192]
        if len(chr_) != n_chr * 8192:
            sys.exit("CHR が途中で切れている")
        n_chr8 = n_chr
    else:
        chr_ram = True
        chr_ = b""
        size = 8192
        if nes2 and rom[11] & 0x0F:                   # NES 2.0: CHR-RAM = 64 << n バイト
            size = max(8192, 64 << (rom[11] & 0x0F))
        n_chr8 = size // 8192
    if n_chr8 not in (1, 2, 4, 8, 16):
        sys.exit(f"CHR {n_chr8}x8KB は未対応 (8〜128KB の 2 のべき乗)")

    mirror_v = rom[6] & 1
    ctrl = (mirror_v << 2) | (int(chr_ram) << 3) | (mapper << 4) | ((n_prg - 1) << 8) | ((n_chr8 - 1) << 12)
    desc = (f"{Path(path).name}: マッパー {mapper} ({MAPPERS[mapper]}) PRG {n_prg * 16}KB "
            f"CHR {n_chr8 * 8}KB {'RAM' if chr_ram else 'ROM'} {'垂直' if mirror_v else '水平'}ミラー"
            f"{' NES2.0' if nes2 else ''} → CTRL {ctrl:04X}")
    return prg, chr_, ctrl, desc
