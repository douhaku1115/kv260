"""段E のコントローラ試験用の PRG を作る (手組みの 6502)。

  python tools/pad_test_gen.py   → roms/pad_prg.hex (32KB を 1 行 4 バイト)

$8000:  SEI / LDX #$FF / TXS
loop:   LDA #1 / STA $4016 / LDA #0 / STA $4016      ; 取り込み合図 1→0
        LDX #0
rd:     LDA $4016 / STA $00,X / INX / CPX #10 / BNE rd ; 10 回読む ($00-$09)
        LDA $4017 / STA $10                            ; 2P
        INC $20                                        ; 1 周ごとに数える
        JMP loop
ベクタ (NMI/RESET/IRQ) はすべて $8000。
"""
from pathlib import Path

code = bytes([
    0x78,                    # 8000 SEI
    0xA2, 0xFF,              # 8001 LDX #$FF
    0x9A,                    # 8003 TXS
    0xA9, 0x01,              # 8004 loop: LDA #1
    0x8D, 0x16, 0x40,        # 8006 STA $4016
    0xA9, 0x00,              # 8009 LDA #0
    0x8D, 0x16, 0x40,        # 800B STA $4016
    0xA2, 0x00,              # 800E LDX #0
    0xAD, 0x16, 0x40,        # 8010 rd: LDA $4016
    0x95, 0x00,              # 8013 STA $00,X
    0xE8,                    # 8015 INX
    0xE0, 0x0A,              # 8016 CPX #10
    0xD0, 0xF6,              # 8018 BNE rd (-10)
    0xAD, 0x17, 0x40,        # 801A LDA $4017
    0x85, 0x10,              # 801D STA $10
    0xE6, 0x20,              # 801F INC $20
    0x4C, 0x04, 0x80,        # 8021 JMP loop
])
prg = bytearray(32768)
prg[:len(code)] = code
prg[0x7FFA:0x8000] = bytes([0x00, 0x80] * 3)

out = Path(__file__).resolve().parent.parent / "roms" / "pad_prg.hex"
out.write_text("".join(f"{int.from_bytes(prg[i:i + 4], 'little'):08X}\n" for i in range(0, 32768, 4)))
print(f"{out.name}: {len(code)} バイトのプログラム")
