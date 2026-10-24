""".nes を、テストベンチ tb_rom が $readmemh で読める形にする。

  python tools/rom_prep.py ROM.nes [フレーム数] [ボタン(16進) 押すフレーム [ボタン2 フレーム2]]
対応: マッパー 0/1/2/3/4/7、PRG 16〜256KB、CHR 8〜128KB (ROM か RAM)。解析は nesrom.py
出力 (roms/ の下、git に入れない。環境変数 HEXDIR があればそこへ):
  rom_prg.hex  PRG を 1 行 4 バイト ([7:0] が若い番地)
  rom_chr.hex  CHR-ROM を 1 行 1 バイト (CHR-RAM なら空)
  rom_cfg.hex  1 行目 = CTRL [15:0] (rtl/mapper.v 参照) / 2 行目 = 回すフレーム数
               3 行目 = 押すボタン (PAD の並び。0 = 押さない) / 4 行目 = 押し始めるフレーム
               5, 6 行目 = 2 回目のボタンとフレーム (無ければ 0)
               (tb_rom はそれぞれ 5 フレーム押して離す)
"""
import os
import sys
from pathlib import Path

from nesrom import load

ROMS = Path(os.environ.get("HEXDIR") or Path(__file__).resolve().parent.parent / "roms")
ROMS.mkdir(parents=True, exist_ok=True)

nframes = int(sys.argv[2]) if len(sys.argv) > 2 else 60
pad = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0
press = int(sys.argv[4]) if len(sys.argv) > 4 else 0
pad2 = int(sys.argv[5], 16) if len(sys.argv) > 5 else 0
press2 = int(sys.argv[6]) if len(sys.argv) > 6 else 0

prg, chr_, ctrl, desc = load(sys.argv[1])

(ROMS / "rom_prg.hex").write_text(
    "".join(f"{int.from_bytes(prg[i:i + 4], 'little'):08X}\n" for i in range(0, len(prg), 4)))
(ROMS / "rom_chr.hex").write_text("".join(f"{b:02X}\n" for b in chr_) or "00\n")
(ROMS / "rom_cfg.hex").write_text(
    f"{ctrl:08X}\n{nframes:08X}\n{pad:08X}\n{press:08X}\n{pad2:08X}\n{press2:08X}\n")
print(f"{desc} / {nframes} フレーム" + (f" / ボタン {pad:02X} をフレーム {press} で押す" if pad else ""))
