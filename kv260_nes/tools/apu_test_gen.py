"""段F の APU 周波数試験用の PRG を作る (手組みの 6502)。

  python tools/apu_test_gen.py   → roms/apu_prg.hex (32KB を 1 行 4 バイト)

矩形波 1: デューティ 50%、長さ停止、一定音量 15、t = 253 → 1789773/(16*254) = 440.40Hz
三角波  : 線形カウンタ停止 (制御 1)、t = 126           → 1789773/(32*127) = 440.40Hz
$4017 = $40 (4 ステップ、フレーム IRQ 禁止)。あとは無限ループ。
ベクタ (NMI/RESET/IRQ) はすべて $8000。
"""
from pathlib import Path


def sta(val, addr):
    """LDA #val / STA addr"""
    return [0xA9, val, 0x8D, addr & 0xFF, addr >> 8]


code = [0x78, 0xA2, 0xFF, 0x9A]          # SEI / LDX #$FF / TXS
code += sta(0x40, 0x4017)                # フレーム IRQ 禁止
code += sta(0x0F, 0x4015)                # 矩形 1/2・三角・ノイズ 有効
code += sta(0xBF, 0x4000)                # デューティ 2, 長さ停止, 一定音量 15
code += sta(0x08, 0x4001)                # スイープ無効 (引き算側 = 無音判定に掛からない)
code += sta(0xFD, 0x4002)                # t 下位 = 253
code += sta(0x00, 0x4003)                # t 上位 = 0, 長さ読み込み
code += sta(0xFF, 0x4008)                # 制御 1, 線形 127
code += sta(0x7E, 0x400A)                # t 下位 = 126
code += sta(0x00, 0x400B)                # t 上位 = 0, 長さ読み込み
loop = 0x8000 + len(code)
code += [0x4C, loop & 0xFF, loop >> 8]   # JMP loop

prg = bytearray(32768)
prg[:len(code)] = bytes(code)
prg[0x7FFA:0x8000] = bytes([0x00, 0x80] * 3)

out = Path(__file__).resolve().parent.parent / "roms" / "apu_prg.hex"
out.write_text("".join(f"{int.from_bytes(prg[i:i + 4], 'little'):08X}\n" for i in range(0, 32768, 4)))
print(f"{out.name}: {len(code)} バイトのプログラム")
