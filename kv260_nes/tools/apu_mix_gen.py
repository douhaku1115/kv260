"""APU のミキサ表 (実機の非線形の式) を hex にする。

  python tools/apu_mix_gen.py → rtl/apu_pulse.hex (31 行), rtl/apu_tnd.hex (203 行)
式は NESdev Wiki "APU Mixer" の表引き版:
  pulse[n] = 95.52 / (8128 / n + 100)          n = 矩形波1 + 矩形波2 (0〜30)
  tnd[n]   = 163.67 / (24329 / n + 100)        n = 3*三角波 + 2*ノイズ + DMC (0〜202)
両方の最大の和 (約 1.0) が SCALE になるよう整数にする (符号なし 16bit)。
"""
from pathlib import Path

SCALE = 30000
RTL = Path(__file__).resolve().parent.parent / "rtl"

pulse = [0.0] + [95.52 / (8128.0 / n + 100) for n in range(1, 31)]
tnd = [0.0] + [163.67 / (24329.0 / n + 100) for n in range(1, 203)]
full = pulse[30] + tnd[202]

(RTL / "apu_pulse.hex").write_text("".join(f"{round(v / full * SCALE):04X}\n" for v in pulse))
(RTL / "apu_tnd.hex").write_text("".join(f"{round(v / full * SCALE):04X}\n" for v in tnd))
print(f"pulse 最大 {round(pulse[30] / full * SCALE)} / tnd 最大 {round(tnd[202] / full * SCALE)}")
